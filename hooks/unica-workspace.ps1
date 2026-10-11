<#
  Cursor workspaceOpen hook for the Unica adapter.

  Input  (stdin, JSON): { "workspace_roots": ["<abs path>", ...], ... }
  Output (stdout, JSON): { "pluginPaths": ["<abs path>"] }  or  {}

  Unica is enabled only when the FIRST workspace root contains
  .cursor/unica.enabled. Unica works with the first MCP root, so a marker in
  any other root must not enable it for a project that did not opt in.

  Any failure results in {} (Unica stays off) and a line in logs/hook.log.
  The script always exits with code 0.

  NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads BOM-less
  files in the ANSI code page.
#>
$ErrorActionPreference = 'Stop'

$UnicaHome = Join-Path (Join-Path $env:USERPROFILE '.cursor') 'unica'
$LogFile = Join-Path (Join-Path $UnicaHome 'logs') 'hook.log'
$MaxLogBytes = 200KB
$KeepLogLines = 500

function Write-HookLog([string]$Message) {
    try {
        $dir = Split-Path -Parent $LogFile
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
        if ((Get-Item -LiteralPath $LogFile).Length -gt $MaxLogBytes) {
            $tail = Get-Content -LiteralPath $LogFile -Tail $KeepLogLines -Encoding UTF8
            Set-Content -LiteralPath $LogFile -Value $tail -Encoding UTF8
        }
    }
    catch {
        # Logging must never break the hook.
    }
}

function Send-HookResult($Result) {
    $json = ConvertTo-Json -InputObject $Result -Compress -Depth 5
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}

function ConvertTo-LocalPath([string]$Root) {
    # Cursor on Windows may pass roots as "/h:/dir", "\h:\dir" or "file:///h:/dir".
    # PowerShell would read the leading "/h:" as a drive named "h" under "/".
    $p = $Root.Trim()
    if ($p -match '^file:///?([A-Za-z]:.*)$') {
        $p = [System.Uri]::UnescapeDataString($Matches[1])
    }
    elseif ($p -match '^[/\\]+([A-Za-z]:.*)$') {
        $p = $Matches[1]
    }
    return $p.Replace('/', '\')
}

function Test-Marker([string]$Root) {
    $Root = ConvertTo-LocalPath $Root
    $marker = Join-Path (Join-Path $Root '.cursor') 'unica.enabled'
    return (Test-Path -LiteralPath $marker -PathType Leaf)
}

$result = [ordered]@{}

try {
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)))
    $raw = $reader.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw 'empty hook input'
    }
    $payload = $raw | ConvertFrom-Json
    $roots = @($payload.workspace_roots | Where-Object { $_ })

    if ($roots.Count -eq 0) {
        Write-HookLog 'no workspace roots: Unica stays off'
    }
    else {
        $first = ConvertTo-LocalPath ([string]$roots[0])
        if (Test-Marker $first) {
            $activeFile = Join-Path $UnicaHome 'active.json'
            $active = $null
            if (Test-Path -LiteralPath $activeFile) {
                $active = [System.IO.File]::ReadAllText($activeFile) | ConvertFrom-Json
            }
            if (-not $active -or -not $active.current) {
                Write-HookLog ('marker found in "{0}", but Unica is not installed (no active.json)' -f $first)
            }
            else {
                $installDir = Join-Path (Join-Path $UnicaHome 'installs') ([string]$active.current)
                if (Test-Path -LiteralPath $installDir -PathType Container) {
                    $result['pluginPaths'] = @($installDir)
                    Write-HookLog ('ENABLED root="{0}" plugin="{1}"' -f $first, $installDir)
                }
                else {
                    Write-HookLog ('marker found in "{0}", but install directory is missing: {1}' -f $first, $installDir)
                }
            }
        }
        else {
            $others = @($roots | Select-Object -Skip 1 | Where-Object { Test-Marker ([string]$_) })
            if ($others.Count -gt 0) {
                Write-HookLog ('marker found only in a non-first root ({0}); Unica works with the first root "{1}", so it stays off' -f ($others -join '; '), $first)
            }
            else {
                Write-HookLog ('off root="{0}" (no marker)' -f $first)
            }
        }
    }
}
catch {
    $result = [ordered]@{}
    Write-HookLog ('ERROR: {0}' -f $_.Exception.Message)
}

try {
    Send-HookResult $result
}
catch {
    Write-HookLog ('ERROR sending result: {0}' -f $_.Exception.Message)
}
exit 0
