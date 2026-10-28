# Offline behavior checks. Run with Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
$adapter = Join-Path (Split-Path -Parent $PSScriptRoot) 'unica-cursor.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($adapter, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
# Load functions only: never dispatch installation or touch the user's profile.
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message - expected '$Expected', got '$Actual'" }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "Expected failure matching $Pattern"
}
function Release($Tag, $Date, $Pre = $true, $Draft = $false) {
    [pscustomobject]@{ tag_name = $Tag; published_at = $Date; prerelease = $Pre; draft = $Draft }
}
$script:releases = @(
    (Release 'v0.15.0-rc.2' '2026-10-24T10:00:00Z')
    (Release 'v0.13.0' '2026-10-09T10:00:00Z' $false)
    (Release 'v0.15.0-rc.10' '2026-10-25T10:00:00Z')
    (Release 'v0.14.0-rc.1' '2026-10-20T10:00:00Z')
    (Release 'v0.13.0-rc.7' '2026-10-08T10:00:00Z')
    (Release 'v0.12.3' '2026-08-01T10:00:00Z' $false)
    (Release 'v0.16.0-beta.1' '2026-10-26T10:00:00Z')
    (Release 'v0.16.0-rc.1' '2026-10-26T10:00:00Z' $true $true)
    (Release 'v0.12.4-rc.1' '2026-10-26T10:00:00Z')
    (Release 'v0.17.0-rc.1' '2026-10-01T10:00:00Z')
    (Release 'nightly' '2026-10-27T10:00:00Z')
)
if (-not (Get-Command Get-ReleaseChoices -ErrorAction SilentlyContinue)) { throw 'Missing release selection feature: Get-ReleaseChoices' }
$choices = @(Get-ReleaseChoices $script:releases)
Assert-Equal (($choices | ForEach-Object { $_.tag_name }) -join ',') 'v0.13.0,v0.15.0-rc.10,v0.15.0-rc.2,v0.14.0-rc.1' 'Stable first, only newer published RCs, numeric ordering'
Assert-Throws { Get-ReleaseChoices @((Release 'v0.15.0-rc.1' '2026-10-26T10:00:00Z')) } 'stable'
Assert-Equal (@(Get-ReleaseChoices @((Release 'v0.13.0' '2026-10-09T10:00:00Z' $false))).Count) 1 'Stable without RCs'
$afterStable = @(Get-ReleaseChoices ($script:releases + @((Release 'v0.14.0' '2026-10-23T10:00:00Z' $false))))
Assert-Equal (($afterStable | ForEach-Object { $_.tag_name }) -join ',') 'v0.14.0,v0.15.0-rc.10,v0.15.0-rc.2' 'New stable removes superseded RCs'
function Get-UnicaReleases { return $script:releases }
Assert-Equal (Resolve-InstallRef 'stable' '') 'v0.13.0' 'Explicit stable'
Assert-Equal (Resolve-InstallRef 'v0.14.0-rc.1' '') 'v0.14.0-rc.1' 'Exact published RC'
Assert-Throws { Resolve-InstallRef 'v0.13.0-rc.7' '' } 'available'
Assert-Throws { Resolve-InstallRef 'stable' 'next' } 'together'
Assert-Throws { Resolve-InstallRef '' '--bad' } 'Invalid'
function Get-UnicaReleases { throw 'API must not be used for -Ref' }
Assert-Equal (Resolve-InstallRef '' 'next') 'next' 'Legacy Ref bypasses release API'
function Get-UnicaReleases { return $script:releases }
$script:answers = [System.Collections.Generic.Queue[string]]::new()
function Read-Host { param($Prompt) return $script:answers.Dequeue() }
$script:answers.Enqueue('')
Assert-Equal (Resolve-InstallRef '' '') 'v0.13.0' 'Enter selects stable'
$script:answers.Enqueue('garbage')
$script:answers.Enqueue('999')
$script:answers.Enqueue('4')
Assert-Equal (Resolve-InstallRef '' '') 'v0.14.0-rc.1' 'Menu retries invalid input and selects numbered RC'
function Read-Host { throw 'NonInteractive host' }
Assert-Throws { Resolve-InstallRef '' '' } 'Use -Version stable'
Write-Host 'release selection: ok'
