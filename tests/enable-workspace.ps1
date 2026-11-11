# Run with Windows PowerShell 5.1, as used by unica-cursor.cmd.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$root = Join-Path $temp ('unica-enable-test-' + [guid]::NewGuid().ToString('N'))
$savedProfile = $env:USERPROFILE
Push-Location -LiteralPath $repo
try {
    $env:USERPROFILE = $root
    $install = Join-Path $root '.cursor/unica/installs/fixture'
    $shim = Join-Path $install 'cursor/unica-cursor-shim.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $shim) -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $root '.cursor/unica/active.json') -Value '{"current":"fixture"}'
    $source = @'
using System;
using System.IO;

class Shim {
    static int Main(string[] args) {
        if (args.Length != 7 || args[0] != "--setup" || args[4] != "run" || args[5] != "--plugin-root") return 2;
        var project = Environment.GetEnvironmentVariable("CLAUDE_PROJECT_DIR").TrimEnd('\\');
        if (args[1].TrimEnd('\\') != project || !Directory.Exists(args[1])) return 3;
        File.WriteAllText(args[2], "{\"data\":{\"setup\":{\"content\":\"version: 1\"}}}");
        return 0;
    }
}
'@
    Add-Type -TypeDefinition $source -OutputAssembly $shim -OutputType ConsoleApplication

    foreach ($launcher in 'unica-cursor.ps1', 'unica-cursor.cmd') {
        $project = Join-Path $root "project with spaces & punctuation! for $launcher"
        New-Item -ItemType Directory -Path $project | Out-Null
        & ".\$launcher" enable -Path ($project + '\') -NoRule
        $config = Join-Path $project 'v8project.yaml'
        if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
            throw "$launcher did not create v8project.yaml for a project path with spaces and a trailing backslash"
        }
        if ([IO.File]::ReadAllText($config) -ne 'version: 1') { throw 'enable did not save the setup response' }
        if (Test-Path -LiteralPath (Join-Path $project '.cursor/rules/unica.mdc')) { throw 'enable did not honor -NoRule' }
    }
    Write-Host 'enable workspace test passed'
}
finally {
    Pop-Location
    $env:USERPROFILE = $savedProfile
    if ((Split-Path -Parent $root).TrimEnd('\') -eq $temp.TrimEnd('\') -and (Test-Path -LiteralPath $root)) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
