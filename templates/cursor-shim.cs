// unica-cursor-shim: stdio bridge between Cursor and the Unica MCP server.
//
//   unica-cursor-shim.exe <server.exe> [server args...]
//       Proxy mode. Fixes what Cursor does differently from the MCP spec:
//       - roots/list answers carry bare Windows paths instead of file:// URIs;
//       - after a reconnect without tools/list Cursor calls tools by its
//         sanitized names (unica_view instead of unica.view);
//       - Cursor shows the agent only `content`, while Unica may answer with
//         an empty `content` and the whole result in `structuredContent`.
//       Set UNICA_CURSOR_SHIM_LOG=<file> to log the traffic.
//
//   unica-cursor-shim.exe --setup <project dir> <out file> <server.exe> [server args...]
//       Starts the server for the project, calls unica.view {} and writes its
//       structuredContent (JSON) to <out file>. Used by unica-cursor.ps1 enable.
//
// Built by unica-cursor.ps1 with the .NET Framework 4 compiler: keep it C# 5
// and ASCII-only.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

internal static class Program
{
    private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 1000 };
    private static readonly Dictionary<string, string> ToolNames = new Dictionary<string, string>();
    private static readonly object ToolNamesLock = new object();
    private static readonly object LogLock = new object();
    private static StreamWriter log;

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length > 0 && args[0] == "--setup")
            {
                if (args.Length < 4)
                {
                    return Usage();
                }
                return RunSetup(args[1], args[2], Slice(args, 3));
            }
            if (args.Length == 0)
            {
                return Usage();
            }
            return RunProxy(args);
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("unica-cursor-shim: " + e.Message);
            return 1;
        }
    }

    private static int Usage()
    {
        Console.Error.WriteLine("usage: unica-cursor-shim <server.exe> [args...]");
        Console.Error.WriteLine("       unica-cursor-shim --setup <project dir> <out file> <server.exe> [args...]");
        return 2;
    }

    // ------------------------------------------------------------------------
    // Proxy mode
    // ------------------------------------------------------------------------
    private static int RunProxy(string[] command)
    {
        OpenLog();
        Process child = StartChild(command);
        StreamWriter childIn = NewWriter(child.StandardInput.BaseStream);
        StreamReader childOut = new StreamReader(child.StandardOutput.BaseStream, Utf8);
        StreamReader clientIn = new StreamReader(Console.OpenStandardInput(), Utf8);
        StreamWriter clientOut = NewWriter(Console.OpenStandardOutput());

        Thread upstream = new Thread(delegate()
        {
            try
            {
                string line;
                while ((line = clientIn.ReadLine()) != null)
                {
                    Log("->", line);
                    childIn.Write(FixClientMessage(line) + "\n");
                    childIn.Flush();
                }
            }
            catch (IOException)
            {
            }
            try
            {
                childIn.Close();
            }
            catch (IOException)
            {
            }
        });
        upstream.IsBackground = true;
        upstream.Start();

        string reply;
        while ((reply = childOut.ReadLine()) != null)
        {
            Log("<-", reply);
            clientOut.Write(FixServerMessage(reply) + "\n");
            clientOut.Flush();
        }
        child.WaitForExit();
        return child.ExitCode;
    }

    private static string FixClientMessage(string line)
    {
        if (line.IndexOf("\"roots\"", StringComparison.Ordinal) < 0 && line.IndexOf("tools/call", StringComparison.Ordinal) < 0)
        {
            return line;
        }
        IDictionary msg = Parse(line);
        if (msg == null)
        {
            return line;
        }
        bool changed = false;

        IDictionary result = msg["result"] as IDictionary;
        IList roots = result != null ? result["roots"] as IList : null;
        if (roots != null)
        {
            foreach (object item in roots)
            {
                IDictionary root = item as IDictionary;
                string uri = root != null ? root["uri"] as string : null;
                if (!string.IsNullOrEmpty(uri) && !uri.StartsWith("file:", StringComparison.OrdinalIgnoreCase))
                {
                    root["uri"] = ToFileUri(uri);
                    changed = true;
                }
            }
        }

        if ("tools/call".Equals(msg["method"] as string))
        {
            IDictionary parameters = msg["params"] as IDictionary;
            string name = parameters != null ? parameters["name"] as string : null;
            if (name != null)
            {
                string original = MapToolName(name);
                if (original != name)
                {
                    parameters["name"] = original;
                    changed = true;
                }
            }
        }

        return changed ? Json.Serialize(msg) : line;
    }

    private static string FixServerMessage(string line)
    {
        if (line.IndexOf("\"tools\"", StringComparison.Ordinal) < 0 && line.IndexOf("structuredContent", StringComparison.Ordinal) < 0)
        {
            return line;
        }
        IDictionary msg = Parse(line);
        IDictionary result = msg != null ? msg["result"] as IDictionary : null;
        if (result == null)
        {
            return line;
        }

        IList tools = result["tools"] as IList;
        if (tools != null)
        {
            RememberToolNames(tools);
        }

        if (!result.Contains("structuredContent"))
        {
            return line;
        }
        IList content = result["content"] as IList;
        if (content != null && content.Count > 0)
        {
            return line;
        }
        Dictionary<string, object> text = new Dictionary<string, object>();
        text["type"] = "text";
        text["text"] = Json.Serialize(result["structuredContent"]);
        result["content"] = new object[] { text };
        return Json.Serialize(msg);
    }

    private static void RememberToolNames(IList tools)
    {
        lock (ToolNamesLock)
        {
            foreach (object item in tools)
            {
                IDictionary tool = item as IDictionary;
                string name = tool != null ? tool["name"] as string : null;
                if (string.IsNullOrEmpty(name))
                {
                    continue;
                }
                ToolNames[name] = name;
                ToolNames[Regex.Replace(name, "[^A-Za-z0-9_-]", "_")] = name;
            }
        }
    }

    private static string MapToolName(string name)
    {
        lock (ToolNamesLock)
        {
            string original;
            if (ToolNames.TryGetValue(name, out original))
            {
                return original;
            }
        }
        // Cursor may skip tools/list after a reconnect; every Unica tool is unica.<dotted name>.
        if (name.StartsWith("unica_", StringComparison.Ordinal))
        {
            return name.Replace('_', '.');
        }
        return name;
    }

    // ------------------------------------------------------------------------
    // Setup mode
    // ------------------------------------------------------------------------
    private const int SetupTimeoutMs = 300000;
    private const int TaskWaitMs = 7000;

    private static int RunSetup(string project, string outFile, string[] command)
    {
        string rootUri = ToFileUri(Path.GetFullPath(project));
        string rootName = Path.GetFileName(Path.GetFullPath(project).TrimEnd('\\', '/'));
        Session session = new Session(StartChild(command), rootUri, rootName);
        try
        {
            Dictionary<string, object> clientInfo = new Dictionary<string, object>();
            clientInfo["name"] = "unica-cursor";
            clientInfo["version"] = "1";
            Dictionary<string, object> roots = new Dictionary<string, object>();
            roots["listChanged"] = false;
            Dictionary<string, object> capabilities = new Dictionary<string, object>();
            capabilities["roots"] = roots;
            Dictionary<string, object> init = new Dictionary<string, object>();
            init["protocolVersion"] = "2025-06-18";
            init["capabilities"] = capabilities;
            init["clientInfo"] = clientInfo;
            session.Request("initialize", init);
            session.Notify("notifications/initialized");

            IDictionary view = session.CallTool("unica.view", new Dictionary<string, object>());
            string taskId;
            while ((taskId = WorkingTaskId(view)) != null)
            {
                Dictionary<string, object> wait = new Dictionary<string, object>();
                wait["taskId"] = taskId;
                wait["waitMs"] = TaskWaitMs;
                view = session.CallTool("unica.task.result", wait);
            }
            File.WriteAllText(outFile, Json.Serialize(view), Utf8);
            return 0;
        }
        finally
        {
            session.Close();
        }
    }

    private static string WorkingTaskId(IDictionary structured)
    {
        IDictionary data = structured["data"] as IDictionary;
        IDictionary task = data != null ? data["task"] as IDictionary : null;
        if (task == null || !"working".Equals(task["status"] as string))
        {
            return null;
        }
        return task["taskId"] as string;
    }

    private sealed class Session
    {
        private readonly Process child;
        private readonly StreamWriter input;
        private readonly object writeLock = new object();
        private readonly object gate = new object();
        private readonly Dictionary<long, IDictionary> responses = new Dictionary<long, IDictionary>();
        private readonly string rootUri;
        private readonly string rootName;
        private readonly DateTime deadline;
        private long nextId = 1;
        private bool closed;

        public Session(Process child, string rootUri, string rootName)
        {
            this.child = child;
            this.rootUri = rootUri;
            this.rootName = rootName;
            deadline = DateTime.UtcNow.AddMilliseconds(SetupTimeoutMs);
            input = NewWriter(child.StandardInput.BaseStream);
            Thread reader = new Thread(ReadLoop);
            reader.IsBackground = true;
            reader.Start();
        }

        public IDictionary CallTool(string name, Dictionary<string, object> arguments)
        {
            Dictionary<string, object> parameters = new Dictionary<string, object>();
            parameters["name"] = name;
            parameters["arguments"] = arguments;
            IDictionary result = Request("tools/call", parameters);
            IDictionary structured = result["structuredContent"] as IDictionary;
            if (structured == null)
            {
                throw new InvalidOperationException(name + " returned no structuredContent: " + Json.Serialize(result));
            }
            return structured;
        }

        public IDictionary Request(string method, Dictionary<string, object> parameters)
        {
            long id;
            lock (gate)
            {
                id = nextId++;
            }
            Dictionary<string, object> msg = new Dictionary<string, object>();
            msg["jsonrpc"] = "2.0";
            msg["id"] = id;
            msg["method"] = method;
            msg["params"] = parameters;
            Send(msg);

            IDictionary reply;
            lock (gate)
            {
                while (!responses.TryGetValue(id, out reply))
                {
                    if (closed)
                    {
                        throw new InvalidOperationException("the Unica server exited before answering " + method);
                    }
                    int left = (int)(deadline - DateTime.UtcNow).TotalMilliseconds;
                    if (left <= 0)
                    {
                        throw new TimeoutException("the Unica server did not answer " + method + " in " + (SetupTimeoutMs / 1000) + " s");
                    }
                    Monitor.Wait(gate, left);
                }
            }
            IDictionary error = reply["error"] as IDictionary;
            if (error != null)
            {
                throw new InvalidOperationException(method + " failed: " + error["message"]);
            }
            IDictionary result = reply["result"] as IDictionary;
            if (result == null)
            {
                throw new InvalidOperationException(method + " returned no result");
            }
            return result;
        }

        public void Notify(string method)
        {
            Dictionary<string, object> msg = new Dictionary<string, object>();
            msg["jsonrpc"] = "2.0";
            msg["method"] = method;
            Send(msg);
        }

        public void Close()
        {
            try
            {
                input.Close();
            }
            catch (IOException)
            {
            }
            try
            {
                if (!child.WaitForExit(5000))
                {
                    child.Kill();
                }
            }
            catch (InvalidOperationException)
            {
            }
        }

        private void Send(IDictionary msg)
        {
            lock (writeLock)
            {
                input.Write(Json.Serialize(msg) + "\n");
                input.Flush();
            }
        }

        private void ReadLoop()
        {
            try
            {
                StreamReader output = new StreamReader(child.StandardOutput.BaseStream, Utf8);
                string line;
                while ((line = output.ReadLine()) != null)
                {
                    IDictionary msg = Parse(line);
                    if (msg == null || !msg.Contains("id") || msg["id"] == null)
                    {
                        continue;
                    }
                    if ("roots/list".Equals(msg["method"] as string))
                    {
                        AnswerRoots(msg["id"]);
                    }
                    else if (!msg.Contains("method"))
                    {
                        lock (gate)
                        {
                            responses[Convert.ToInt64(msg["id"])] = msg;
                            Monitor.PulseAll(gate);
                        }
                    }
                }
            }
            catch (IOException)
            {
            }
            lock (gate)
            {
                closed = true;
                Monitor.PulseAll(gate);
            }
        }

        private void AnswerRoots(object id)
        {
            Dictionary<string, object> root = new Dictionary<string, object>();
            root["uri"] = rootUri;
            root["name"] = rootName;
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["roots"] = new object[] { root };
            Dictionary<string, object> msg = new Dictionary<string, object>();
            msg["jsonrpc"] = "2.0";
            msg["id"] = id;
            msg["result"] = result;
            Send(msg);
        }
    }

    // ------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------
    private static Process StartChild(string[] command)
    {
        ProcessStartInfo info = new ProcessStartInfo(command[0], JoinArguments(Slice(command, 1)));
        info.UseShellExecute = false;
        info.RedirectStandardInput = true;
        info.RedirectStandardOutput = true;
        info.StandardOutputEncoding = Utf8;
        return Process.Start(info);
    }

    private static StreamWriter NewWriter(Stream stream)
    {
        StreamWriter writer = new StreamWriter(stream, Utf8);
        writer.AutoFlush = false;
        writer.NewLine = "\n";
        return writer;
    }

    private static IDictionary Parse(string line)
    {
        try
        {
            return Json.DeserializeObject(line) as IDictionary;
        }
        catch (ArgumentException)
        {
            return null;
        }
        catch (InvalidOperationException)
        {
            return null;
        }
    }

    private static string ToFileUri(string path)
    {
        string local = Regex.Replace(path.Trim(), @"^[/\\]+([A-Za-z]:)", "$1");
        try
        {
            return new Uri(local).AbsoluteUri;
        }
        catch (UriFormatException)
        {
            return path;
        }
    }

    private static string[] Slice(string[] items, int start)
    {
        string[] result = new string[Math.Max(0, items.Length - start)];
        Array.Copy(items, start, result, 0, result.Length);
        return result;
    }

    // Quotes arguments the way CommandLineToArgvW reads them back.
    private static string JoinArguments(string[] items)
    {
        StringBuilder sb = new StringBuilder();
        foreach (string item in items)
        {
            if (sb.Length > 0)
            {
                sb.Append(' ');
            }
            if (item.Length > 0 && item.IndexOfAny(new[] { ' ', '\t', '"' }) < 0)
            {
                sb.Append(item);
                continue;
            }
            sb.Append('"');
            int backslashes = 0;
            foreach (char c in item)
            {
                if (c == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (c == '"')
                {
                    sb.Append('\\', backslashes * 2 + 1);
                }
                else
                {
                    sb.Append('\\', backslashes);
                }
                backslashes = 0;
                sb.Append(c);
            }
            sb.Append('\\', backslashes * 2);
            sb.Append('"');
        }
        return sb.ToString();
    }

    private static void OpenLog()
    {
        string file = Environment.GetEnvironmentVariable("UNICA_CURSOR_SHIM_LOG");
        if (string.IsNullOrEmpty(file))
        {
            return;
        }
        try
        {
            log = new StreamWriter(file, true, Utf8);
            log.AutoFlush = true;
            log.WriteLine("=== start pid=" + Process.GetCurrentProcess().Id + " cwd=" + Environment.CurrentDirectory);
        }
        catch (IOException)
        {
            log = null;
        }
        catch (UnauthorizedAccessException)
        {
            log = null;
        }
    }

    private static void Log(string direction, string line)
    {
        if (log == null)
        {
            return;
        }
        lock (LogLock)
        {
            log.WriteLine(DateTime.Now.ToString("HH:mm:ss") + " " + direction + " " + line);
        }
    }
}
