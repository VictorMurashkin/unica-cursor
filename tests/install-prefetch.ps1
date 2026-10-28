# Offline regression: installation must deliver engines before activation,
# including reuse, and must preserve the active version on bootstrap failure.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'unica-cursor.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('unica-prefetch-test-' + [guid]::NewGuid().ToString('N'))
$UnicaHome = $root
$SourceDir = Join-Path $root 'source'
$InstallsDir = Join-Path $root 'installs'
$LogsDir = Join-Path $root 'logs'
$RuntimesDir = Join-Path $root 'runtimes'
$ProviderStateDir = Join-Path $root 'provider-state'
$ActiveFile = Join-Path $root 'active.json'
$TemplatesDir = Join-Path $repo 'templates'
$script:BootstrapRelPath = 'bootstrap/bin/win-x64/unica-bootstrap.exe'
$script:AdapterVersion = 2
$script:MinVersion = '0.13.0-rc.6'
$script:BoundParams = @{}
$Version = 'v0.15.0-rc.1'
$Ref = ''
$McpMode = 'roots'
$Prefetch = $false
$Force = $false
$commit = 'b1196e9b90feb88704f550e1a7f3964103bccfc3'
$name = '0.15.0-rc.1-b1196e9-roots-a2'
$install = Join-Path $InstallsDir $name
# Replace only external network/host integration. Execute the real installer,
# JSON state functions and environment wrapper against disposable directories.
function Assert-Environment { }
function Resolve-InstallRef { return 'v0.15.0-rc.1' }
function Invoke-Git { }
function Resolve-Commit { return $commit }
function Test-McpCompatibility { return $true }
function Set-ModeLink { param($Name, $State) $script:linked = $Name }
function Register-Hook { }
function Remove-OldInstalls { }
try {
    foreach ($dir in @((Join-Path $SourceDir '.git'), (Join-Path $SourceDir '.claude-plugin'), (Join-Path $SourceDir 'plugins/unica/.claude-plugin'), (Join-Path $install 'bootstrap/bin/win-x64'))) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Write-JsonFile (Join-Path $SourceDir '.claude-plugin/marketplace.json') @{ plugins = @(@{ name = 'unica'; source = 'plugins/unica' }) }
    Write-JsonFile (Join-Path $SourceDir 'plugins/unica/.claude-plugin/plugin.json') @{ version = '0.15.0-rc.1' }
    $packageBootstrap = Join-Path $SourceDir 'plugins/unica/bootstrap/bin/win-x64/unica-bootstrap.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $packageBootstrap) -Force | Out-Null
    Set-Content -LiteralPath $packageBootstrap -Value 'fixture'
    Set-Content -LiteralPath (Join-Path $SourceDir 'plugins/unica/bootstrap/launch.sh') -Value 'run --plugin-root'
    Write-JsonFile (Join-Path $install '.unica-cursor-state.json') @{ version = '0.15.0-rc.1'; packageCommit = $commit; mcpMode = 'roots'; adapterVersion = 2 }
    # Native fixture exposes the same process exit/environment boundary as bootstrap.
    $source = @'
using System;
using System.IO;
class Bootstrap {
    static int Main(string[] args) {
        if (args.Length != 3 || args[0] != "prefetch" || args[1] != "--plugin-root" || !Directory.Exists(args[2])) return 90;
        var cache = Environment.GetEnvironmentVariable("UNICA_RUNTIME_CACHE_DIR");
        var state = Environment.GetEnvironmentVariable("UNICA_PROVIDER_STATE_DIR");
        if (!Directory.Exists(cache) || !Directory.Exists(state)) return 91;
        if (Environment.GetEnvironmentVariable("UNICA_HOST_CONTEXT_REQUIRED") != "1") return 92;
        if (File.Exists(Path.Combine(cache, "fail"))) return 42;
        File.WriteAllText(Path.Combine(cache, "delivered"), File.ReadAllText(Path.Combine(cache, "..", "active.json")));
        return 0;
    }
}
'@
    Add-Type -TypeDefinition $source -OutputAssembly (Join-Path $install $script:BootstrapRelPath) -OutputType ConsoleApplication
    foreach ($command in 'install', 'update') {
        $Command = $command
        foreach ($explicitPrefetch in $false, $true) {
            $Prefetch = $explicitPrefetch
            Save-Active 'old-version' 'older-version'
            $script:linked = $null
            Invoke-Install
            $delivered = Join-Path $RuntimesDir 'delivered'
            if (-not (Test-Path -LiteralPath $delivered)) { throw "$command without -Prefetch did not deliver engines" }
            $atDelivery = Read-JsonFile $delivered
            if ($atDelivery.current -ne 'old-version') { throw 'Version was activated before engine delivery' }
            if ((Get-Active).current -ne $name -or (Get-Active).previous -ne 'old-version' -or $script:linked -ne $name) { throw 'Successful installation was not activated with rollback' }
            Remove-Item -LiteralPath $delivered

            Save-Active 'old-version' 'older-version'
            $before = [IO.File]::ReadAllText($ActiveFile)
            $script:linked = $null
            Set-Content -LiteralPath (Join-Path $RuntimesDir 'fail') -Value 'fail'
            $failure = $null
            try { Invoke-Install } catch { $failure = $_.Exception.Message }
            if (-not $failure -or $failure -notmatch '42') { throw 'Bootstrap failure was not reported with its exit code' }
            if ([IO.File]::ReadAllText($ActiveFile) -ne $before -or $script:linked) { throw 'Failed download changed the active installation' }
            Remove-Item -LiteralPath (Join-Path $RuntimesDir 'fail')
        }
    }
    Write-Host 'install/update engine delivery and failure atomicity: ok'
}
finally {
    if ((Split-Path -Parent ([IO.Path]::GetFullPath($root))) -ne ([IO.Path]::GetTempPath()).TrimEnd('\')) { throw 'Unexpected test cleanup path' }
    Remove-Item -LiteralPath $root -Recurse -Force
}
