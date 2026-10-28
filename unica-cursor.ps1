<#
.SYNOPSIS
  Installs Unica (https://github.com/IngvarConsulting/unica) into Cursor and
  enables it per project through a marker file.

.DESCRIPTION
  Commands:
    install   [-Version stable|vX.Y.Z-rc.N | -Ref <ref>] [-McpMode roots|project] [-Prefetch] [-ExpandPaths] [-Force]
    update    same parameters as install
    rollback
    enable    [-Path <project>] [-NoWorkspaceConfig] [-NoRule] [-Force]
    disable   [-Path <project>]
    status    [-Path <project>]
    uninstall [-KeepCache]

  Every installed version lives in its own immutable directory under
  ~/.cursor/unica/installs. active.json points to the current and the previous
  installation. A global workspaceOpen hook (~/.cursor/hooks.json) loads the
  active installation only for windows whose FIRST workspace root contains
  .cursor/unica.enabled.

  Cursor talks to Unica through unica-cursor-shim.exe (templates/cursor-shim.cs,
  compiled into every installation): it fixes how Cursor deviates from the MCP
  spec. enable also writes v8project.yaml from the configuration Unica detects,
  a v8project.local.yaml.example for the infobase connection, portable .gitignore
  rules for Unica generated paths, and the agent rule .cursor/rules/unica.mdc.

  See README.md and docs/usage.md.

  NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads BOM-less
  files in the ANSI code page, which corrupts non-ASCII characters.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('install', 'update', 'rollback', 'enable', 'disable', 'status', 'uninstall')]
    [string]$Command,

    # Manual branch (main, next), tag or commit of unica-marketplace. Bypasses the version menu.
    [string]$Ref,

    # Latest stable or an exact published RC newer than stable. Omit to show a menu.
    [string]$Version,

    # roots: MCP server inside the plugin (default). project: server in <project>/.cursor/mcp.json.
    [ValidateSet('roots', 'project')]
    [string]$McpMode,

    # Compatibility switch: install/update always download the core and ALL engines.
    [switch]$Prefetch,

    # Replace ${userHome} / ${CURSOR_PLUGIN_ROOT} in generated MCP configs with absolute paths.
    [switch]$ExpandPaths,

    # Project directory for enable / disable / status. Default: current directory.
    [Parameter(Position = 1)]
    [string]$Path,

    [switch]$Force,

    # enable: do not create v8project.yaml and v8project.local.yaml.example.
    [switch]$NoWorkspaceConfig,

    # enable: do not create or update the agent rule .cursor/rules/unica.mdc.
    [switch]$NoRule,

    # uninstall: keep downloaded runtimes and provider state.
    [switch]$KeepCache
)

$ErrorActionPreference = 'Stop'
# Inside functions $PSBoundParameters is the function's own, so keep the script's.
$script:BoundParams = $PSBoundParameters
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# ----------------------------------------------------------------------------
# Constants and paths
# ----------------------------------------------------------------------------
$script:AdapterVersion = 2
$script:MinVersion = '0.13.0-rc.6'
$script:MarketplaceUrl = 'https://github.com/IngvarConsulting/unica-marketplace'
$script:HookScriptName = 'unica-workspace.ps1'
$script:HookCommand = 'powershell -NoProfile -ExecutionPolicy Bypass -File ./hooks/unica-workspace.ps1'
$script:ProjectServerName = 'unica'
$script:ShimRelPath = 'cursor\unica-cursor-shim.exe'
$script:BootstrapRelPath = 'bootstrap\bin\win-x64\unica-bootstrap.exe'
$script:WorkspaceConfigName = 'v8project.yaml'
$script:LocalConfigName = 'v8project.local.yaml'
$script:LocalExampleName = 'v8project.local.yaml.example'
# Patterns Unica requires before repositoryReady, plus the directories it
# creates while working. .build/ covers the workspace cache and the source-set
# probe <source>/.build/.unica-health-probe. /build/* covers the root build
# tree (infobase, logs, tools) and does not ignore a build directory in sources.
$script:GeneratedGitIgnorePatterns = @(
    '.build/'
    '.build/unica'
    '**/.build/'
    '/build/*'
    'ConfigDumpInfo.xml'
    'DumpFilesIndex.txt'
)
$script:RuleBlockPattern = '(?s)<!-- unica-cursor:begin.*?<!-- unica-cursor:end -->'

if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    throw 'USERPROFILE is not set.'
}
$CursorHome = Join-Path $env:USERPROFILE '.cursor'
$UnicaHome = Join-Path $CursorHome 'unica'
$SourceDir = Join-Path $UnicaHome 'source'
$InstallsDir = Join-Path $UnicaHome 'installs'
$ActiveFile = Join-Path $UnicaHome 'active.json'
$CurrentLink = Join-Path $UnicaHome 'current'
$RuntimesDir = Join-Path $UnicaHome 'runtimes'
$ProviderStateDir = Join-Path $UnicaHome 'provider-state'
$LogsDir = Join-Path $UnicaHome 'logs'
$HooksDir = Join-Path $CursorHome 'hooks'
$HooksJson = Join-Path $CursorHome 'hooks.json'
$TemplatesDir = Join-Path $PSScriptRoot 'templates'
$HookTemplate = Join-Path (Join-Path $PSScriptRoot 'hooks') $script:HookScriptName

# ----------------------------------------------------------------------------
# Output and logging
# ----------------------------------------------------------------------------
function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Info([string]$Message) { Write-Host "    $Message" }
function Write-Warn([string]$Message) { Write-Host "WARNING: $Message" -ForegroundColor Yellow }

function Write-InstallLog([string]$Message) {
    try {
        if (-not (Test-Path -LiteralPath $LogsDir)) {
            New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
        }
        $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath (Join-Path $LogsDir 'install.log') -Value $line -Encoding UTF8
    }
    catch { }
}

function Confirm-Action([string]$Prompt) {
    if ($Force) { return $true }
    $answer = Read-Host "$Prompt [y/N]"
    return ($answer -match '^(y|yes)$')
}

# ----------------------------------------------------------------------------
# JSON and file helpers
# ----------------------------------------------------------------------------
function Read-TextFile([string]$File) {
    return [System.IO.File]::ReadAllText($File, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-TextFile([string]$File, [string]$Text) {
    $dir = Split-Path -Parent $File
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($File, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-JsonFile([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $null }
    $text = Read-TextFile $File
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try {
        return ($text | ConvertFrom-Json)
    }
    catch {
        throw "Cannot parse JSON file '$File': $($_.Exception.Message)"
    }
}

# Writes through a temporary file and a rename, so readers never see half a file.
function Write-JsonFile([string]$File, $Object) {
    $json = ConvertTo-Json -InputObject $Object -Depth 20
    $tmp = "$File.tmp"
    Write-TextFile $tmp ($json + [Environment]::NewLine)
    Move-Item -LiteralPath $tmp -Destination $File -Force
}

function Set-JsonProp($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    }
    else {
        Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Test-JsonProp($Object, [string]$Name) {
    return ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name])
}

# ----------------------------------------------------------------------------
# Environment, git, semver
# ----------------------------------------------------------------------------
function Assert-Environment {
    if ($env:OS -ne 'Windows_NT') {
        throw 'This script supports Windows x64 only.'
    }
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    if ($arch -ne 'AMD64') {
        throw "Unsupported processor architecture '$arch'. Unica bootstrap for Windows is win-x64 only."
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git was not found in PATH. Install Git for Windows first.'
    }
}

function Invoke-Git([string[]]$GitArgs) {
    & git @GitArgs | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw ("git {0} failed with exit code {1}" -f ($GitArgs -join ' '), $LASTEXITCODE)
    }
}

# Resolves a branch, tag or commit of the source clone to a full commit hash, or $null.
function Resolve-Commit([string]$Name) {
    foreach ($candidate in @("origin/$Name", "refs/tags/$Name", $Name)) {
        $out = & git -C $SourceDir rev-parse --verify --quiet "$candidate^{commit}" 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            return ([string]$out).Trim()
        }
    }
    return $null
}

function ConvertTo-SemVer([string]$Text) {
    if ($Text -notmatch '^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.\-]+))?(?:\+.*)?$') { return $null }
    return [pscustomobject]@{
        Major = [int]$Matches[1]
        Minor = [int]$Matches[2]
        Patch = [int]$Matches[3]
        Pre   = $Matches[4]
    }
}

function Compare-SemVer($A, $B) {
    foreach ($part in 'Major', 'Minor', 'Patch') {
        if ($A.$part -ne $B.$part) { return [Math]::Sign($A.$part - $B.$part) }
    }
    if (-not $A.Pre -and -not $B.Pre) { return 0 }
    if (-not $A.Pre) { return 1 }
    if (-not $B.Pre) { return -1 }
    $left = $A.Pre.Split('.')
    $right = $B.Pre.Split('.')
    $count = [Math]::Max($left.Count, $right.Count)
    for ($i = 0; $i -lt $count; $i++) {
        if ($i -ge $left.Count) { return -1 }
        if ($i -ge $right.Count) { return 1 }
        $x = $left[$i]
        $y = $right[$i]
        $xNum = ($x -match '^\d+$')
        $yNum = ($y -match '^\d+$')
        if ($xNum -and $yNum) {
            $d = [int]$x - [int]$y
            if ($d -ne 0) { return [Math]::Sign($d) }
        }
        elseif ($xNum) { return -1 }
        elseif ($yNum) { return 1 }
        else {
            $c = [string]::CompareOrdinal($x, $y)
            if ($c -ne 0) { return [Math]::Sign($c) }
        }
    }
    return 0
}

# Published releases define the user-facing choices; the matching marketplace
# tag still supplies the complete plugin, including bootstrap and skills.
function Get-UnicaReleases {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'unica-cursor' }
    $page = 1
    do {
        try {
            # Assign first: Windows PowerShell 5.1 emits a REST JSON array as one object.
            $response = Invoke-RestMethod -Uri "https://api.github.com/repos/IngvarConsulting/unica/releases?per_page=100&page=$page" -Headers $headers -TimeoutSec 30
            $batch = @($response)
        }
        catch {
            throw "Cannot load Unica releases from GitHub (check network access and API rate limits). Retry later or use -Ref with a known marketplace tag. $($_.Exception.Message)"
        }
        $batch
        $page++
    } while ($batch.Count -eq 100)
}

function Get-ReleaseChoices([object[]]$Releases) {
    $stable = $null
    foreach ($release in $Releases) {
        if ($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^v\d+\.\d+\.\d+$') { continue }
        if (-not $stable -or (Compare-SemVer (ConvertTo-SemVer $release.tag_name) (ConvertTo-SemVer $stable.tag_name)) -gt 0) {
            $stable = $release
        }
    }
    if (-not $stable) { throw 'GitHub returned no published stable Unica release.' }

    $candidates = New-Object 'System.Collections.Generic.List[object]'
    $stableVersion = ConvertTo-SemVer $stable.tag_name
    foreach ($release in $Releases) {
        if ($release.draft -or -not $release.prerelease -or $release.tag_name -notmatch '^v\d+\.\d+\.\d+-rc\.\d+$') { continue }
        $candidateVersion = ConvertTo-SemVer $release.tag_name
        if ((Compare-SemVer $candidateVersion $stableVersion) -le 0 -or
            [DateTimeOffset]$release.published_at -le [DateTimeOffset]$stable.published_at) { continue }
        $index = 0
        while ($index -lt $candidates.Count -and
            (Compare-SemVer $candidateVersion (ConvertTo-SemVer $candidates[$index].tag_name)) -lt 0) { $index++ }
        $candidates.Insert($index, $release)
    }
    $stable
    $candidates
}

function Resolve-InstallRef([string]$RequestedVersion, [string]$RequestedRef) {
    if ($RequestedRef) {
        if ($RequestedVersion) { throw '-Version and -Ref cannot be used together.' }
        if ($RequestedRef -notmatch '^[A-Za-z0-9][A-Za-z0-9._/\-]*$') { throw "Invalid -Ref value '$RequestedRef'." }
        return $RequestedRef
    }
    $choices = @(Get-ReleaseChoices @(Get-UnicaReleases))
    if ($RequestedVersion) {
        if ($RequestedVersion -eq 'stable') { return [string]$choices[0].tag_name }
        $selected = @($choices | Where-Object { $_.tag_name -ceq $RequestedVersion })
        if ($selected.Count -eq 0) {
            throw "Version '$RequestedVersion' is not available. Choose stable or one of: $(($choices | ForEach-Object { $_.tag_name }) -join ', ')."
        }
        return [string]$selected[0].tag_name
    }
    Write-Step 'Choose a Unica version'
    for ($i = 0; $i -lt $choices.Count; $i++) {
        $label = 'RC (pre-release)'
        if ($i -eq 0) { $label = 'latest stable, default' }
        Write-Info ("{0}. {1} ({2})" -f ($i + 1), $choices[$i].tag_name, $label)
    }
    do {
        try { $answer = Read-Host 'Version number [1]' }
        catch { throw 'Cannot read version selection. Use -Version stable or -Version vX.Y.Z-rc.N for unattended installation.' }
        if ([string]::IsNullOrWhiteSpace($answer)) { return [string]$choices[0].tag_name }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $choices.Count) {
            return [string]$choices[$number - 1].tag_name
        }
        Write-Warn "Enter a number from 1 to $($choices.Count)."
    } while ($true)
}

# ----------------------------------------------------------------------------
# State: active.json and per-install state
# ----------------------------------------------------------------------------
function Get-Active { return Read-JsonFile $ActiveFile }

function Get-InstallState([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    return Read-JsonFile (Join-Path (Join-Path $InstallsDir $Name) '.unica-cursor-state.json')
}

function Save-Active([string]$Current, [string]$Previous) {
    $obj = [ordered]@{
        current   = $Current
        previous  = $Previous
        updatedAt = (Get-Date).ToString('o')
    }
    Write-JsonFile $ActiveFile $obj
}

function Get-InstallName([string]$Version, [string]$Commit, [string]$Mode, [bool]$Expand) {
    $safeVersion = $Version -replace '[^0-9A-Za-z.\-]', '_'
    $name = '{0}-{1}-{2}-a{3}' -f $safeVersion, $Commit.Substring(0, 7), $Mode, $script:AdapterVersion
    if ($Expand) { $name += '-abs' }
    return $name
}

# ----------------------------------------------------------------------------
# Installation directories, locks, junction
# ----------------------------------------------------------------------------
# A running unica-bootstrap.exe keeps its file open; opening it for writing then fails.
function Test-InstallInUse([string]$InstallDir) {
    $exe = Join-Path $InstallDir 'bootstrap\bin\win-x64\unica-bootstrap.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $false }
    try {
        $stream = [System.IO.File]::Open($exe, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream.Close()
        return $false
    }
    catch [System.IO.IOException] { return $true }
    catch { return $false }
}

function Remove-CurrentLink {
    $item = Get-Item -LiteralPath $CurrentLink -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        [System.IO.Directory]::Delete($CurrentLink)
    }
    else {
        throw "'$CurrentLink' exists and is not a junction. Remove it manually."
    }
}

function Set-CurrentLink([string]$Target) {
    Remove-CurrentLink
    New-Item -ItemType Junction -Path $CurrentLink -Value $Target | Out-Null
}

function Set-ModeLink([string]$InstallName, $State) {
    if ($State -and $State.mcpMode -eq 'project') {
        Set-CurrentLink (Join-Path $InstallsDir $InstallName)
    }
    else {
        Remove-CurrentLink
    }
}

function Remove-OldInstalls([string]$Current, [string]$Previous) {
    if (-not (Test-Path -LiteralPath $InstallsDir)) { return }
    foreach ($dir in @(Get-ChildItem -LiteralPath $InstallsDir -Directory -Force)) {
        if ($dir.Name -eq $Current -or $dir.Name -eq $Previous) { continue }
        try {
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
            Write-InstallLog "removed old installation $($dir.Name)"
        }
        catch {
            Write-InstallLog "could not remove $($dir.Name) (in use?): $($_.Exception.Message)"
            Write-Warn "Could not remove old installation '$($dir.Name)' (probably in use). It will be removed on the next run."
        }
    }
}

# ----------------------------------------------------------------------------
# MCP compatibility check (structural comparison of the upstream .mcp.json)
# ----------------------------------------------------------------------------
function Get-McpLines($Json) {
    $lines = New-Object System.Collections.Generic.List[string]
    if (-not (Test-JsonProp $Json 'mcpServers') -or $null -eq $Json.mcpServers) {
        $lines.Add('<no mcpServers>')
        return $lines.ToArray()
    }
    foreach ($server in $Json.mcpServers.PSObject.Properties) {
        $name = $server.Name
        $value = $server.Value
        $lines.Add("[$name] server")
        $lines.Add("[$name] command = $($value.command)")
        if ($value.args) {
            $i = 0
            foreach ($arg in @($value.args)) {
                $lines.Add("[$name] args[$i] = $arg")
                $i++
            }
        }
        $lines.Add("[$name] cwd = $($value.cwd)")
        if ($value.env) {
            foreach ($entry in ($value.env.PSObject.Properties | Sort-Object Name)) {
                $lines.Add("[$name] env.$($entry.Name) = $($entry.Value)")
            }
        }
    }
    return $lines.ToArray()
}

# Returns $true when the package launch contract equals the one our templates were written for.
function Test-McpCompatibility([string]$PackageMcpFile) {
    $expectedFile = Join-Path $TemplatesDir 'upstream-mcp.json'
    $expected = Read-JsonFile $expectedFile
    $actual = Read-JsonFile $PackageMcpFile
    if ($null -eq $expected) { throw "Missing reference file: $expectedFile" }
    if ($null -eq $actual) { throw "The package has no .mcp.json: $PackageMcpFile" }

    $expectedLines = @(Get-McpLines $expected)
    $actualLines = @(Get-McpLines $actual)
    $diff = @(Compare-Object -ReferenceObject $expectedLines -DifferenceObject $actualLines -CaseSensitive)

    # Informational only: startup_timeout_sec does not affect our configs.
    foreach ($serverName in 'unica') {
        $oldT = $expected.mcpServers.$serverName.startup_timeout_sec
        $newT = $actual.mcpServers.$serverName.startup_timeout_sec
        if ($oldT -ne $newT) {
            Write-Info "startup_timeout_sec changed: $oldT -> $newT (informational, Cursor ignores it)"
        }
    }

    if ($diff.Count -eq 0) { return $true }

    Write-Host ''
    Write-Host 'The upstream launch contract (.mcp.json) differs from templates/upstream-mcp.json:' -ForegroundColor Yellow
    foreach ($d in $diff) {
        if ($d.SideIndicator -eq '<=') { Write-Host "  - $($d.InputObject)" -ForegroundColor Red }
        else { Write-Host "  + $($d.InputObject)" -ForegroundColor Green }
    }
    Write-Host '  ("-" = expected by the adapter, "+" = found in the package)'
    Write-Host ''
    return $false
}

# ----------------------------------------------------------------------------
# Template expansion
# ----------------------------------------------------------------------------
function Expand-TemplateText([string]$Text, [bool]$Expand, [string]$PluginRoot) {
    if (-not $Expand) { return $Text }
    $profilePath = $env:USERPROFILE.Replace('\', '/')
    $result = $Text.Replace('${userHome}', $profilePath)
    if ($PluginRoot) {
        $result = $result.Replace('${CURSOR_PLUGIN_ROOT}', $PluginRoot.Replace('\', '/'))
    }
    return $result
}

function Get-ProjectServerEntry([bool]$Expand) {
    $text = Read-TextFile (Join-Path $TemplatesDir 'project-mcp.json')
    $text = Expand-TemplateText $text $Expand $null
    $doc = $text | ConvertFrom-Json
    return $doc.mcpServers.unica
}

# ----------------------------------------------------------------------------
# Cursor shim and calls to Unica
# ----------------------------------------------------------------------------
function Build-Shim([string]$InstallRoot) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
        throw "The .NET Framework 4 C# compiler was not found: $csc. It is needed to build the Cursor shim."
    }
    $source = Join-Path $TemplatesDir 'cursor-shim.cs'
    $exe = Join-Path $InstallRoot $script:ShimRelPath
    $dir = Split-Path -Parent $exe
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $output = & $csc /nologo /optimize+ /target:exe /r:System.Web.Extensions.dll "/out:$exe" $source 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw ("Building the Cursor shim failed (csc exit code {0}):`n{1}" -f $LASTEXITCODE, (($output | Out-String).Trim()))
    }
}

# Runs $Body with the environment the Unica server gets from mcp.json.
function Invoke-WithUnicaEnv([hashtable]$Extra, [scriptblock]$Body) {
    $vars = @{
        UNICA_RUNTIME_CACHE_DIR     = $RuntimesDir
        UNICA_PROVIDER_STATE_DIR    = $ProviderStateDir
        UNICA_HOST_CONTEXT_REQUIRED = '1'
    }
    if ($Extra) { foreach ($key in $Extra.Keys) { $vars[$key] = $Extra[$key] } }
    $saved = @{}
    foreach ($name in $vars.Keys) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        foreach ($name in $vars.Keys) { [Environment]::SetEnvironmentVariable($name, $vars[$name], 'Process') }
        & $Body
    }
    finally {
        foreach ($name in $vars.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
}

# Returns the structuredContent of unica.view {} for the project.
function Get-UnicaWorkspaceView([string]$InstallDir, [string]$ProjectRoot) {
    $shim = Join-Path $InstallDir $script:ShimRelPath
    if (-not (Test-Path -LiteralPath $shim -PathType Leaf)) {
        throw 'The active installation has no Cursor shim. Run "unica-cursor.ps1 update" first.'
    }
    $bootstrap = Join-Path $InstallDir $script:BootstrapRelPath
    $outFile = Join-Path ([System.IO.Path]::GetTempPath()) ('unica-view-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        Invoke-WithUnicaEnv @{ CLAUDE_PROJECT_DIR = $ProjectRoot } {
            & $shim --setup $ProjectRoot $outFile $bootstrap run --plugin-root $InstallDir | Out-Host
        }
        if ($LASTEXITCODE -ne 0) { throw "unica-cursor-shim --setup exited with code $LASTEXITCODE" }
        $view = Read-JsonFile $outFile
        if ($null -eq $view) { throw 'Unica returned an empty answer to unica.view {}.' }
        return $view
    }
    finally {
        if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force }
    }
}

function New-WorkspaceConfig([string]$InstallDir, [string]$ProjectRoot) {
    $file = Join-Path $ProjectRoot $script:WorkspaceConfigName
    Write-Step "Asking Unica for the workspace configuration (the first run downloads the Unica core)"
    try {
        $view = Get-UnicaWorkspaceView $InstallDir $ProjectRoot
    }
    catch {
        Write-Warn "Could not get the workspace configuration from Unica: $($_.Exception.Message)"
        Write-Info 'Rerun enable later, or ask the agent: it calls unica.view {} and writes the content of "setup".'
        return
    }
    $setup = $null
    if ((Test-JsonProp $view 'data') -and (Test-JsonProp $view.data 'setup')) { $setup = $view.data.setup }
    $content = $null
    if ($setup -and (Test-JsonProp $setup 'content')) { $content = [string]$setup.content }
    if ([string]::IsNullOrWhiteSpace($content)) {
        Write-Warn "Unica did not propose a $($script:WorkspaceConfigName): $($view.summary)"
        if ($setup -and $setup.reason) { Write-Info $setup.reason }
        Write-Info "Add the 1C sources (Designer XML or EDT) to the project and rerun enable."
        return
    }
    Write-TextFile $file $content
    Write-Host "Workspace configuration created: $file" -ForegroundColor Green
    foreach ($set in @($view.data.sourceSets)) {
        if ($set) { Write-Info ("  {0}: {1} at {2} ({3})" -f $set.name, $set.kind, $set.path, $set.sourceFormat) }
    }
    Write-Info 'Check it in Cursor with unica.check {}. Machine-specific settings (infobase) go to v8project.local.yaml.'
}

# ----------------------------------------------------------------------------
# hooks.json registration
# ----------------------------------------------------------------------------
function Test-HookRegistered {
    $doc = Read-JsonFile $HooksJson
    if ($null -eq $doc -or -not (Test-JsonProp $doc 'hooks') -or -not (Test-JsonProp $doc.hooks 'workspaceOpen')) { return $false }
    foreach ($entry in @($doc.hooks.workspaceOpen)) {
        if ($entry -and $entry.command -like "*$script:HookScriptName*") { return $true }
    }
    return $false
}

function Register-Hook {
    if (-not (Test-Path -LiteralPath $HookTemplate -PathType Leaf)) {
        throw "Hook script template not found: $HookTemplate"
    }
    if (-not (Test-Path -LiteralPath $HooksDir)) {
        New-Item -ItemType Directory -Path $HooksDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $HookTemplate -Destination (Join-Path $HooksDir $script:HookScriptName) -Force

    $doc = Read-JsonFile $HooksJson
    if ($null -eq $doc) { $doc = [pscustomobject]@{} }
    if (Test-Path -LiteralPath $HooksJson) {
        Copy-Item -LiteralPath $HooksJson -Destination "$HooksJson.bak" -Force
    }
    if (-not (Test-JsonProp $doc 'version')) { Set-JsonProp $doc 'version' 1 }
    if (-not (Test-JsonProp $doc 'hooks') -or $null -eq $doc.hooks) { Set-JsonProp $doc 'hooks' ([pscustomobject]@{}) }

    $existing = @()
    if (Test-JsonProp $doc.hooks 'workspaceOpen') { $existing = @($doc.hooks.workspaceOpen) }
    $kept = @($existing | Where-Object { $_ -and -not ($_.command -like "*$script:HookScriptName*") })
    $entry = [pscustomobject]@{ command = $script:HookCommand }
    Set-JsonProp $doc.hooks 'workspaceOpen' (@($kept) + $entry)
    Write-JsonFile $HooksJson $doc
}

function Unregister-Hook {
    $doc = Read-JsonFile $HooksJson
    if ($null -ne $doc -and (Test-JsonProp $doc 'hooks') -and (Test-JsonProp $doc.hooks 'workspaceOpen')) {
        Copy-Item -LiteralPath $HooksJson -Destination "$HooksJson.bak" -Force
        $kept = @(@($doc.hooks.workspaceOpen) | Where-Object { $_ -and -not ($_.command -like "*$script:HookScriptName*") })
        if ($kept.Count -gt 0) {
            Set-JsonProp $doc.hooks 'workspaceOpen' $kept
        }
        else {
            $doc.hooks.PSObject.Properties.Remove('workspaceOpen')
        }
        $hookProps = @($doc.hooks.PSObject.Properties)
        $topProps = @($doc.PSObject.Properties | Where-Object { $_.Name -ne 'hooks' -and $_.Name -ne 'version' })
        if ($hookProps.Count -eq 0 -and $topProps.Count -eq 0) {
            Remove-Item -LiteralPath $HooksJson -Force
        }
        else {
            Write-JsonFile $HooksJson $doc
        }
    }
    $script = Join-Path $HooksDir $script:HookScriptName
    if (Test-Path -LiteralPath $script) { Remove-Item -LiteralPath $script -Force }
}

# ----------------------------------------------------------------------------
# Project helpers (marker and project-level mcp.json)
# ----------------------------------------------------------------------------
function Resolve-ProjectPath {
    $target = $Path
    if ([string]::IsNullOrWhiteSpace($target)) { $target = (Get-Location).ProviderPath }
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        throw "Project directory not found: $target"
    }
    return (Resolve-Path -LiteralPath $target).ProviderPath
}

function Get-MarkerFile([string]$ProjectRoot) {
    return (Join-Path (Join-Path $ProjectRoot '.cursor') 'unica.enabled')
}

function Get-ProjectMcpFile([string]$ProjectRoot) {
    return (Join-Path (Join-Path $ProjectRoot '.cursor') 'mcp.json')
}

function Get-RuleFile([string]$ProjectRoot) {
    return (Join-Path (Join-Path (Join-Path $ProjectRoot '.cursor') 'rules') 'unica.mdc')
}

# Creates the rule from the template, or puts the managed block into an existing rule file.
function Set-ProjectRule([string]$ProjectRoot) {
    $file = Get-RuleFile $ProjectRoot
    $template = (Read-TextFile (Join-Path $TemplatesDir 'unica-rule.mdc')).Replace("`r`n", "`n")
    $block = [regex]::Match($template, $script:RuleBlockPattern).Value
    if (-not $block) { throw 'templates/unica-rule.mdc has no unica-cursor:begin/end block.' }

    if (-not (Test-Path -LiteralPath $file)) {
        Write-TextFile $file $template
        return 'created'
    }
    $text = (Read-TextFile $file).Replace("`r`n", "`n")
    $match = [regex]::Match($text, $script:RuleBlockPattern)
    if ($match.Success) {
        $new = $text.Substring(0, $match.Index) + $block + $text.Substring($match.Index + $match.Length)
        if ($new -eq $text) { return 'unchanged' }
        $result = 'updated'
    }
    else {
        $new = $text.TrimEnd() + "`n`n" + $block + "`n"
        $result = 'appended'
    }
    Copy-Item -LiteralPath $file -Destination "$file.bak" -Force
    Write-TextFile $file $new
    return $result
}

function Remove-ProjectRule([string]$ProjectRoot) {
    $file = Get-RuleFile $ProjectRoot
    if (-not (Test-Path -LiteralPath $file)) { return $false }
    $text = (Read-TextFile $file).Replace("`r`n", "`n")
    $match = [regex]::Match($text, $script:RuleBlockPattern)
    if (-not $match.Success) { return $false }
    $rest = ($text.Substring(0, $match.Index) + $text.Substring($match.Index + $match.Length)).Trim()
    $rest = [regex]::Replace($rest, "\n{3,}", "`n`n")
    $withoutFrontMatter = ([regex]::Replace($rest, '(?s)^---\n.*?\n---', '')).Trim()
    Copy-Item -LiteralPath $file -Destination "$file.bak" -Force
    if ($withoutFrontMatter) {
        Write-TextFile $file ($rest + "`n")
    }
    else {
        Remove-Item -LiteralPath $file -Force
    }
    return $true
}

function New-LocalConfigExample([string]$ProjectRoot) {
    $file = Join-Path $ProjectRoot $script:LocalExampleName
    if (Test-Path -LiteralPath $file) {
        Write-Info "$($script:LocalExampleName) already exists; left untouched."
        return
    }
    Copy-Item -LiteralPath (Join-Path $TemplatesDir $script:LocalExampleName) -Destination $file
    Write-Host "Infobase connection example created: $file" -ForegroundColor Green
    if (Test-Path -LiteralPath (Join-Path $ProjectRoot $script:LocalConfigName)) {
        Write-Info "$($script:LocalConfigName) already exists: compare it with the example if the infobase is not found."
    }
    else {
        Write-Info "To connect an infobase: copy it to $($script:LocalConfigName) and fill in the connection."
    }
}

# Keeps the machine-specific config (paths, passwords) out of Git.
function Add-GitIgnoreEntry([string]$ProjectRoot, [string]$Entry) {
    $file = Join-Path $ProjectRoot '.gitignore'
    $text = ''
    if (Test-Path -LiteralPath $file) { $text = Read-TextFile $file }
    foreach ($line in ($text -split "`r?`n")) {
        if ($line.Trim() -eq $Entry -or $line.Trim() -eq "/$Entry") { return }
    }
    if ($text -and -not $text.EndsWith("`n")) { $text += "`n" }
    Write-TextFile $file ($text + "/$Entry`n")
    Write-Info "Added /$Entry to $file"
}

# Adds the portable ignore rules Unica checks (.build/ cache, root /build/*
# outputs, source-set .build probe, Designer ConfigDumpInfo.xml and
# DumpFilesIndex.txt). Exact lines that are already present are left as they are.
function Add-GeneratedGitIgnore([string]$ProjectRoot) {
    $file = Join-Path $ProjectRoot '.gitignore'
    $text = ''
    if (Test-Path -LiteralPath $file) { $text = Read-TextFile $file }
    $present = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($line in ($text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed) { [void]$present.Add($trimmed) }
    }
    $missing = @()
    foreach ($pattern in $script:GeneratedGitIgnorePatterns) {
        if (-not $present.Contains($pattern)) { $missing += $pattern }
    }
    if ($missing.Count -eq 0) { return }
    if ($text -and -not $text.EndsWith("`n")) { $text += "`n" }
    Write-TextFile $file ($text + (($missing -join "`n") + "`n"))
    Write-Info ("Added to {0}: {1}" -f $file, ($missing -join ', '))
}

function Test-OurServerEntry($Entry) {
    if ($null -eq $Entry) { return $false }
    $command = [string]$Entry.command
    return ($command -like '*unica-bootstrap*' -or $command -like '*unica-cursor-shim*')
}

function Add-ProjectMcpEntry([string]$ProjectRoot, $Entry) {
    $file = Get-ProjectMcpFile $ProjectRoot
    $doc = Read-JsonFile $file
    if ($null -eq $doc) { $doc = [pscustomobject]@{} }
    if (Test-JsonProp $doc 'mcpServers') {
        if ((Test-JsonProp $doc.mcpServers $script:ProjectServerName) -and -not (Test-OurServerEntry $doc.mcpServers.($script:ProjectServerName)) -and -not $Force) {
            throw "'$file' already contains a different MCP server named '$($script:ProjectServerName)'. Use -Force to replace it."
        }
    }
    else {
        Set-JsonProp $doc 'mcpServers' ([pscustomobject]@{})
    }
    if (Test-Path -LiteralPath $file) { Copy-Item -LiteralPath $file -Destination "$file.bak" -Force }
    Set-JsonProp $doc.mcpServers $script:ProjectServerName $Entry
    Write-JsonFile $file $doc
}

function Remove-ProjectMcpEntry([string]$ProjectRoot) {
    $file = Get-ProjectMcpFile $ProjectRoot
    $doc = Read-JsonFile $file
    if ($null -eq $doc -or -not (Test-JsonProp $doc 'mcpServers')) { return $false }
    if (-not (Test-JsonProp $doc.mcpServers $script:ProjectServerName)) { return $false }
    if (-not (Test-OurServerEntry $doc.mcpServers.($script:ProjectServerName))) {
        Write-Warn "The '$($script:ProjectServerName)' server in '$file' was not created by this adapter; left untouched."
        return $false
    }
    Copy-Item -LiteralPath $file -Destination "$file.bak" -Force
    $doc.mcpServers.PSObject.Properties.Remove($script:ProjectServerName)
    $serverCount = @($doc.mcpServers.PSObject.Properties).Count
    $otherTop = @($doc.PSObject.Properties | Where-Object { $_.Name -ne 'mcpServers' }).Count
    if ($serverCount -eq 0 -and $otherTop -eq 0) {
        Remove-Item -LiteralPath $file -Force
    }
    else {
        Write-JsonFile $file $doc
    }
    return $true
}

# ----------------------------------------------------------------------------
# install / update
# ----------------------------------------------------------------------------
function Invoke-Install {
    Assert-Environment

    foreach ($required in 'plugin.json', 'mcp.json', 'project-mcp.json', 'upstream-mcp.json', 'cursor-shim.cs') {
        if (-not (Test-Path -LiteralPath (Join-Path $TemplatesDir $required))) {
            throw "Template not found: $(Join-Path $TemplatesDir $required)"
        }
    }

    $requestedRef = Resolve-InstallRef $Version $Ref

    $active = Get-Active
    $activeState = $null
    if ($active) { $activeState = Get-InstallState $active.current }

    $mode = $McpMode
    if (-not $mode) {
        if ($activeState -and $activeState.mcpMode) { $mode = $activeState.mcpMode } else { $mode = 'roots' }
    }
    if ($script:BoundParams.ContainsKey('ExpandPaths')) {
        $expand = [bool]$ExpandPaths
    }
    else {
        $expand = [bool]($activeState -and $activeState.expandPaths)
    }

    foreach ($dir in $UnicaHome, $InstallsDir, $LogsDir, $RuntimesDir, $ProviderStateDir) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }

    # 1. Source clone ---------------------------------------------------------
    Write-Step "Fetching unica-marketplace ($requestedRef)"
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir '.git'))) {
        if ((Test-Path -LiteralPath $SourceDir) -and @(Get-ChildItem -LiteralPath $SourceDir -Force).Count -gt 0) {
            throw "'$SourceDir' exists but is not a git clone. Remove it and retry."
        }
        $cloned = $false
        try {
            Invoke-Git @('-c', 'core.autocrlf=false', '-c', 'core.longpaths=true', 'clone', '--quiet', '--filter=blob:none', $script:MarketplaceUrl, $SourceDir)
            $cloned = $true
        }
        catch {
            Write-Warn 'Partial clone failed, retrying with a full clone.'
            if (Test-Path -LiteralPath $SourceDir) { Remove-Item -LiteralPath $SourceDir -Recurse -Force }
        }
        if (-not $cloned) {
            Invoke-Git @('-c', 'core.autocrlf=false', '-c', 'core.longpaths=true', 'clone', '--quiet', $script:MarketplaceUrl, $SourceDir)
        }
        Invoke-Git @('-C', $SourceDir, 'config', 'core.autocrlf', 'false')
        Invoke-Git @('-C', $SourceDir, 'config', 'core.longpaths', 'true')
    }
    else {
        Invoke-Git @('-C', $SourceDir, 'fetch', '--quiet', '--tags', '--prune', '--force', 'origin')
    }

    $marketCommit = Resolve-Commit $requestedRef
    if (-not $marketCommit) {
        throw "Ref '$requestedRef' was not found in unica-marketplace."
    }
    Invoke-Git @('-C', $SourceDir, 'checkout', '--quiet', '--detach', '--force', $marketCommit)

    # 2. Package ref (like Codex / Claude Code do) -----------------------------
    $marketplace = Read-JsonFile (Join-Path $SourceDir '.claude-plugin\marketplace.json')
    if ($null -eq $marketplace) {
        throw "'.claude-plugin/marketplace.json' not found at '$requestedRef'. The marketplace layout may have changed."
    }
    $entry = @($marketplace.plugins | Where-Object { $_.name -eq 'unica' }) | Select-Object -First 1
    if ($null -eq $entry) {
        throw "Plugin 'unica' is not listed in marketplace.json at '$requestedRef'."
    }

    $source = $entry.source
    $packageRef = $null
    $packageCommit = $marketCommit
    $subPath = $null
    if ($source -is [string]) {
        $subPath = $source
        $packageRef = '(marketplace checkout)'
    }
    elseif ($source -and $source.source -eq 'git-subdir' -and ([string]$source.url) -match 'IngvarConsulting/unica-marketplace(\.git)?/?$') {
        if (-not $source.ref -or -not $source.path) {
            throw "marketplace.json: git-subdir source without 'ref' or 'path'."
        }
        $packageRef = [string]$source.ref
        $subPath = [string]$source.path
        $packageCommit = Resolve-Commit $packageRef
        if (-not $packageCommit) {
            throw "Package ref '$packageRef' from marketplace.json was not found in the repository."
        }
        if ($packageCommit -ne $marketCommit) {
            Invoke-Git @('-C', $SourceDir, 'checkout', '--quiet', '--detach', '--force', $packageCommit)
        }
    }
    else {
        throw 'Unsupported plugin source format in marketplace.json. The marketplace layout changed; review the adapter before installing.'
    }

    $subPath = $subPath.Trim().TrimStart('.', '/', '\').Replace('/', '\')
    if ([string]::IsNullOrWhiteSpace($subPath) -or $subPath -match '(^|\\)\.\.(\\|$)' -or [System.IO.Path]::IsPathRooted($subPath)) {
        throw "Unsafe package path in marketplace.json: '$subPath'."
    }
    $packageDir = Join-Path $SourceDir $subPath
    if (-not (Test-Path -LiteralPath $packageDir -PathType Container)) {
        throw "Package directory not found: $packageDir"
    }

    # 3. Version checks --------------------------------------------------------
    $packageManifest = Read-JsonFile (Join-Path $packageDir '.claude-plugin\plugin.json')
    if ($null -eq $packageManifest -or -not $packageManifest.version) {
        throw "Cannot read the package version from '.claude-plugin/plugin.json'."
    }
    $version = [string]$packageManifest.version
    $semver = ConvertTo-SemVer $version
    if ($null -eq $semver) { throw "Unrecognised package version '$version'." }
    $min = ConvertTo-SemVer $script:MinVersion
    if ((Compare-SemVer $semver $min) -lt 0) {
        throw "Package version $version is not supported. The adapter relies on the host-context mechanism of Unica $($script:MinVersion) and newer."
    }
    if ($requestedRef -match '^v\d+\.\d+\.\d+(-[0-9A-Za-z.\-]+)?$') {
        if ($requestedRef.Substring(1) -ne $version) {
            throw "Tag '$requestedRef' points to a catalog of version $version, not $($requestedRef.Substring(1)). Tags between v0.9.1 and v0.13.0-rc.5 install the previous version; install by branch (-Ref main or -Ref next) instead."
        }
    }
    Write-Info "Package version: $version (ref $packageRef, commit $($packageCommit.Substring(0, 7)))"

    # 4. Launch contract compatibility -----------------------------------------
    $packageMcp = Join-Path $packageDir '.mcp.json'
    if (-not (Test-McpCompatibility $packageMcp)) {
        if ($Force) {
            Write-Warn 'Continuing despite the launch contract change (-Force).'
        }
        else {
            throw 'The way Unica is launched has changed. Review templates/mcp.json and templates/project-mcp.json, update templates/upstream-mcp.json, then rerun (or use -Force to install anyway).'
        }
    }
    $bootstrapExe = Join-Path $packageDir 'bootstrap\bin\win-x64\unica-bootstrap.exe'
    if (-not (Test-Path -LiteralPath $bootstrapExe -PathType Leaf)) {
        throw "Package has no bootstrap/bin/win-x64/unica-bootstrap.exe (looked in $packageDir)."
    }
    $launchSh = Join-Path $packageDir 'bootstrap\launch.sh'
    if (-not (Test-Path -LiteralPath $launchSh -PathType Leaf) -or (Read-TextFile $launchSh) -notmatch 'run\s+--plugin-root') {
        $message = "bootstrap/launch.sh does not call 'run --plugin-root' any more; the bootstrap command line may have changed."
        if ($Force) { Write-Warn $message } else { throw $message }
    }

    # 5-6. Build the installation ----------------------------------------------
    $installName = Get-InstallName $version $packageCommit $mode $expand
    $installDir = Join-Path $InstallsDir $installName
    $reuse = $false
    if (Test-Path -LiteralPath $installDir) {
        $existingState = Get-InstallState $installName
        if ($existingState -and $existingState.packageCommit -eq $packageCommit -and $existingState.mcpMode -eq $mode -and $existingState.adapterVersion -eq $script:AdapterVersion) {
            $reuse = $true
            Write-Step "Installation $installName already exists, reusing it"
        }
        else {
            try { Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction Stop }
            catch { throw "Incomplete installation '$installName' cannot be removed (in use?). Close Cursor and retry." }
        }
    }

    if (-not $reuse) {
        Write-Step "Building installation $installName (MCP mode: $mode)"
        $tmp = Join-Path $InstallsDir ('.new-' + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            & robocopy $packageDir $tmp /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }

            # Keep the upstream launcher out of auto-discovery, so Cursor never starts it.
            $upstreamMcp = Join-Path $tmp '.mcp.json'
            if (Test-Path -LiteralPath $upstreamMcp) {
                Move-Item -LiteralPath $upstreamMcp -Destination (Join-Path $tmp '.mcp.json.upstream') -Force
            }

            # Cursor manifest.
            $manifest = (Read-TextFile (Join-Path $TemplatesDir 'plugin.json')) | ConvertFrom-Json
            Set-JsonProp $manifest 'version' $version
            Write-JsonFile (Join-Path (Join-Path $tmp '.cursor-plugin') 'plugin.json') $manifest

            Build-Shim $tmp

            # MCP server inside the plugin (roots mode only).
            if ($mode -eq 'roots') {
                $mcpText = Expand-TemplateText (Read-TextFile (Join-Path $TemplatesDir 'mcp.json')) $expand $installDir
                $null = $mcpText | ConvertFrom-Json
                Write-TextFile (Join-Path $tmp 'mcp.json') $mcpText
            }

            $state = [ordered]@{
                schema           = 1
                adapterVersion   = $script:AdapterVersion
                name             = $installName
                version          = $version
                requestedRef     = $requestedRef
                marketplaceCommit = $marketCommit
                packageRef       = $packageRef
                packageCommit    = $packageCommit
                mcpMode          = $mode
                expandPaths      = $expand
                installedAt      = (Get-Date).ToString('o')
            }
            Write-JsonFile (Join-Path $tmp '.unica-cursor-state.json') $state

            Move-Item -LiteralPath $tmp -Destination $installDir
        }
        catch {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
            throw
        }
        Write-InstallLog "built $installName (ref $requestedRef, package $packageRef, commit $packageCommit, mode $mode)"
    }

    # 7. Lock check (project mode: the junction is switched immediately) --------
    if ($mode -eq 'project' -and $active -and $active.current -and $active.current -ne $installName) {
        if (Test-InstallInUse (Join-Path $InstallsDir $active.current)) {
            Write-Warn 'Unica is running from the current installation. In project mode the switch takes effect after the unica server is restarted in every window.'
            if (-not (Confirm-Action 'Switch anyway?')) {
                throw 'Cancelled. The new installation was built but not activated.'
            }
        }
    }

    # 8. Deliver every pinned runtime before changing the active installation.
    # Also run for reused installations to repair incomplete runtime caches.
    Write-Step 'Prefetching the Unica core and all engines (this can take a while)'
    $exe = Join-Path $installDir $script:BootstrapRelPath
    Invoke-WithUnicaEnv $null {
        & $exe prefetch --plugin-root $installDir | Out-Host
        # Check in this scope: the environment wrapper does not propagate
        # a native process's LASTEXITCODE back to its caller.
        if ($LASTEXITCODE -ne 0) {
            throw "Runtime prefetch failed with exit code $LASTEXITCODE. The active installation was not changed. Check network access and rerun install/update."
        }
    }

    # 9. Switch ----------------------------------------------------------------
    $newState = Get-InstallState $installName
    $previous = $null
    if ($active -and $active.current) {
        if ($active.current -ne $installName) { $previous = $active.current } else { $previous = $active.previous }
    }
    Set-ModeLink $installName $newState
    Save-Active $installName $previous
    Write-Step "Active installation: $installName"
    Write-InstallLog "activated $installName (previous: $previous)"

    # 10-11. Cleanup and hook --------------------------------------------------
    Remove-OldInstalls $installName $previous
    Write-Step 'Registering the workspaceOpen hook'
    Register-Hook

    # 12. Summary --------------------------------------------------------------
    Write-Host ''
    Write-Host "Unica $version installed (mode: $mode)." -ForegroundColor Green
    Write-Info "Installation: $installDir"
    if ($mode -eq 'project') {
        Write-Info "Project mode: 'enable' adds the unica server to <project>\.cursor\mcp.json."
        Write-Info "Projects enabled by an older adapter: rerun 'enable' to switch their server entry to the Cursor shim."
    }
    Write-Info 'Next steps:'
    Write-Info '  1. In a project: unica-cursor.ps1 enable -Path <project>   (creates .cursor\unica.enabled)'
    Write-Info '  2. In Cursor: Developer: Reload Window, then start a NEW chat.'
    Write-Info 'Windows that are already open keep using the previous version until reloaded.'
}

# ----------------------------------------------------------------------------
# rollback
# ----------------------------------------------------------------------------
function Invoke-Rollback {
    $active = Get-Active
    if (-not $active -or -not $active.previous) {
        throw 'There is no previous installation to roll back to.'
    }
    $previousDir = Join-Path $InstallsDir $active.previous
    if (-not (Test-Path -LiteralPath $previousDir -PathType Container)) {
        throw "The previous installation '$($active.previous)' no longer exists on disk."
    }
    $state = Get-InstallState $active.previous
    if ($state -and $state.mcpMode -eq 'project' -and $active.current -and (Test-InstallInUse (Join-Path $InstallsDir $active.current))) {
        Write-Warn 'Unica is running from the current installation. In project mode the switch takes effect after the unica server is restarted.'
        if (-not (Confirm-Action 'Switch anyway?')) { throw 'Cancelled.' }
    }
    Set-ModeLink $active.previous $state
    Save-Active $active.previous $active.current
    Write-InstallLog "rollback: $($active.current) -> $($active.previous)"
    Write-Host "Rolled back to $($active.previous)." -ForegroundColor Green
    if ($state) {
        Write-Info "Version: $($state.version), commit: $($state.packageCommit), MCP mode: $($state.mcpMode)"
    }
    Write-Info 'Run "Developer: Reload Window" in Cursor and start a new chat. Run rollback again to switch back.'
}

# ----------------------------------------------------------------------------
# enable / disable / status
# ----------------------------------------------------------------------------
function Invoke-Enable {
    $active = Get-Active
    if (-not $active -or -not $active.current) {
        throw 'Unica is not installed. Run "unica-cursor.ps1 install" first.'
    }
    $project = Resolve-ProjectPath
    $state = Get-InstallState $active.current

    $marker = Get-MarkerFile $project
    Write-TextFile $marker ("Unica is enabled for this project (managed by unica-cursor.ps1).`r`nDelete this file to disable it.`r`n")
    Write-Host "Marker created: $marker" -ForegroundColor Green

    if ($state -and $state.mcpMode -eq 'project') {
        $entry = Get-ProjectServerEntry ([bool]$state.expandPaths)
        Add-ProjectMcpEntry $project $entry
        Write-Info "Server 'unica' added to $(Get-ProjectMcpFile $project)"
    }

    Add-GeneratedGitIgnore $project

    $config = Join-Path $project $script:WorkspaceConfigName
    if (Test-Path -LiteralPath $config) {
        Write-Info "$($script:WorkspaceConfigName) already exists; left untouched."
    }
    elseif ($NoWorkspaceConfig) {
        Write-Info "$($script:WorkspaceConfigName) was not created (-NoWorkspaceConfig). Unica still detects source sets automatically."
    }
    else {
        New-WorkspaceConfig (Join-Path $InstallsDir $active.current) $project
    }
    if (-not $NoWorkspaceConfig) {
        New-LocalConfigExample $project
        Add-GitIgnoreEntry $project $script:LocalConfigName
    }

    if ($NoRule) {
        Write-Info 'Agent rule was not created (-NoRule).'
    }
    else {
        $ruleFile = Get-RuleFile $project
        switch (Set-ProjectRule $project) {
            'created'   { Write-Host "Agent rule created: $ruleFile" -ForegroundColor Green }
            'appended'  { Write-Host "Unica block added to the existing rule: $ruleFile" -ForegroundColor Green }
            'updated'   { Write-Host "Unica block updated in: $ruleFile" -ForegroundColor Green }
            'unchanged' { Write-Info "Agent rule is up to date: $ruleFile" }
        }
    }
    Write-Info 'In a multi-root workspace the 1C project must be the FIRST folder.'
    Write-Info 'Now run "Developer: Reload Window" in Cursor and start a new chat.'
}

function Invoke-Disable {
    $project = Resolve-ProjectPath
    $marker = Get-MarkerFile $project
    if (Test-Path -LiteralPath $marker) {
        Remove-Item -LiteralPath $marker -Force
        Write-Host "Marker removed: $marker" -ForegroundColor Green
    }
    else {
        Write-Info 'The marker file did not exist.'
    }
    if (Remove-ProjectMcpEntry $project) {
        Write-Info "Server 'unica' removed from $(Get-ProjectMcpFile $project)"
    }
    if (Remove-ProjectRule $project) {
        Write-Info "Unica block removed from $(Get-RuleFile $project)"
    }
    Write-Info "$($script:WorkspaceConfigName) and $($script:LocalConfigName) describe the project; left untouched."
    Write-Info 'Now run "Developer: Reload Window" in Cursor and start a new chat.'
}

function Invoke-Status {
    $active = Get-Active
    Write-Host 'Unica adapter for Cursor' -ForegroundColor Cyan
    Write-Info "Home: $UnicaHome"
    if ($active -and $active.current) {
        $state = Get-InstallState $active.current
        Write-Info "Active:   $($active.current)"
        if ($state) {
            Write-Info "          version $($state.version), ref $($state.requestedRef), package ref $($state.packageRef), commit $($state.packageCommit), MCP mode $($state.mcpMode)"
        }
        else {
            Write-Warn 'The state file of the active installation is missing.'
        }
        $shim = Join-Path (Join-Path $InstallsDir $active.current) $script:ShimRelPath
        Write-Info ("Cursor shim: {0}" -f $(if (Test-Path -LiteralPath $shim) { 'present' } else { 'missing (run update)' }))
        if ($active.previous) {
            $prevExists = Test-Path -LiteralPath (Join-Path $InstallsDir $active.previous)
            Write-Info "Previous: $($active.previous)$(if (-not $prevExists) { ' (missing on disk)' })"
        }
        else {
            Write-Info 'Previous: none (rollback unavailable)'
        }
    }
    else {
        Write-Info 'Not installed.'
    }
    Write-Info ("Hook registered: {0}" -f $(if (Test-HookRegistered) { 'yes' } else { 'no' }))
    Write-Info ("Hook script:     {0}" -f $(if (Test-Path -LiteralPath (Join-Path $HooksDir $script:HookScriptName)) { 'present' } else { 'missing' }))

    $project = Resolve-ProjectPath
    Write-Host ''
    Write-Host "Project: $project" -ForegroundColor Cyan
    Write-Info ("Marker (.cursor\unica.enabled): {0}" -f $(if (Test-Path -LiteralPath (Get-MarkerFile $project)) { 'present' } else { 'absent' }))
    $doc = Read-JsonFile (Get-ProjectMcpFile $project)
    $hasEntry = ($null -ne $doc -and (Test-JsonProp $doc 'mcpServers') -and (Test-JsonProp $doc.mcpServers $script:ProjectServerName))
    Write-Info ("Project .cursor\mcp.json has 'unica': {0}" -f $(if ($hasEntry) { 'yes' } else { 'no' }))
    foreach ($name in $script:WorkspaceConfigName, $script:LocalConfigName, $script:LocalExampleName) {
        Write-Info ("{0} in the root: {1}" -f $name, $(if (Test-Path -LiteralPath (Join-Path $project $name)) { 'yes' } else { 'no' }))
    }
    $ruleFile = Get-RuleFile $project
    $hasRule = (Test-Path -LiteralPath $ruleFile) -and [regex]::IsMatch((Read-TextFile $ruleFile), $script:RuleBlockPattern)
    Write-Info ("Agent rule (.cursor\rules\unica.mdc): {0}" -f $(if ($hasRule) { 'yes' } else { 'no' }))
}

# ----------------------------------------------------------------------------
# uninstall
# ----------------------------------------------------------------------------
function Invoke-Uninstall {
    Write-Step 'Removing the workspaceOpen hook'
    Unregister-Hook

    Write-Step 'Removing installations'
    Remove-CurrentLink
    if (Test-Path -LiteralPath $ActiveFile) { Remove-Item -LiteralPath $ActiveFile -Force }

    $leftovers = @()
    foreach ($target in @($InstallsDir, $SourceDir)) {
        if (Test-Path -LiteralPath $target) {
            try { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop }
            catch { $leftovers += $target }
        }
    }
    if (Test-Path -LiteralPath $LogsDir) {
        Remove-Item -LiteralPath $LogsDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not $KeepCache) {
        foreach ($target in @($RuntimesDir, $ProviderStateDir)) {
            if (Test-Path -LiteralPath $target) {
                try { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop }
                catch { $leftovers += $target }
            }
        }
    }
    else {
        Write-Info 'Kept: runtimes and provider-state.'
    }

    if ((Test-Path -LiteralPath $UnicaHome) -and @(Get-ChildItem -LiteralPath $UnicaHome -Force).Count -eq 0) {
        Remove-Item -LiteralPath $UnicaHome -Force
    }

    Write-Host 'Unica was uninstalled.' -ForegroundColor Green
    if ($leftovers.Count -gt 0) {
        Write-Warn 'Some directories are in use and were not removed. Close Cursor and delete them manually:'
        foreach ($item in $leftovers) { Write-Info "  $item" }
    }
    Write-Info 'Project markers (.cursor\unica.enabled) and project-level .cursor\mcp.json entries were NOT touched.'
    Write-Info 'Run "Developer: Reload Window" in Cursor.'
}

# ----------------------------------------------------------------------------
# Dispatch
# ----------------------------------------------------------------------------
try {
    switch ($Command) {
        'install'   { Invoke-Install }
        'update'    { Invoke-Install }
        'rollback'  { Invoke-Rollback }
        'enable'    { Invoke-Enable }
        'disable'   { Invoke-Disable }
        'status'    { Invoke-Status }
        'uninstall' { Invoke-Uninstall }
    }
}
catch {
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    Write-InstallLog ("ERROR ($Command): " + $_.Exception.Message)
    exit 1
}
