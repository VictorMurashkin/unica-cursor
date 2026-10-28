$ErrorActionPreference = 'Stop'
$adapter = Join-Path (Split-Path -Parent $PSScriptRoot) 'unica-cursor.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($adapter, [ref]$tokens, [ref]$errors)
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
$script:requests = @()
function Invoke-RestMethod {
    param($Uri, $Headers, $TimeoutSec)
    $script:requests += $Uri
    if ($Uri -match 'page=1$') {
        $items = @(1..100 | ForEach-Object { [pscustomobject]@{ tag_name = "v0.1.0-rc.$_" } })
    }
    elseif ($Uri -match 'page=2$') {
        $items = @([pscustomobject]@{ tag_name = 'v0.13.0'; prerelease = $false; draft = $false; published_at = '2026-10-09T10:00:00Z' })
    }
    else { throw 'Unexpected page' }
    # Windows PowerShell 5.1 REST JSON arrays are emitted as a single object.
    Write-Output -NoEnumerate $items
}
$releases = @(Get-UnicaReleases)
if ($releases.Count -ne 101 -or $script:requests.Count -ne 2) { throw "Pagination/array handling: expected 101 releases in 2 requests, got $($releases.Count) in $($script:requests.Count)" }
$choices = @(Get-ReleaseChoices $releases)
if ($choices.Count -ne 1 -or $choices[0].tag_name -ne 'v0.13.0') { throw 'Stable on second page was lost' }
function Invoke-RestMethod { throw 'Simulated API rate limit' }
try { Get-UnicaReleases; throw 'Expected API failure' } catch {
    if ($_.Exception.Message -notmatch 'Cannot load Unica releases.*Simulated API rate limit') { throw }
}
Write-Host 'release API pagination and failures: ok'
