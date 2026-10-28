# Live GitHub integration check; installs into a disposable USERPROFILE.
$ErrorActionPreference = 'Stop'
$adapter = Join-Path (Split-Path -Parent $PSScriptRoot) 'unica-cursor.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('unica-release-test-' + [guid]::NewGuid().ToString('N'))
$originalProfile = $env:USERPROFILE
$originalModuleCache = $env:PSModuleAnalysisCachePath
New-Item -ItemType Directory -Path $root | Out-Null
function Assert-Runtimes([string]$UnicaHome, [string]$InstallName) {
    $manifest = Get-Content -LiteralPath (Join-Path $UnicaHome "installs/$InstallName/runtime-manifest.json") -Raw | ConvertFrom-Json
    foreach ($entry in $manifest.artifacts.PSObject.Properties) {
        $artifact = $entry.Value
        $target = $artifact.targets.'win-x64'
        if (-not $target) { continue }
        $cache = Join-Path $UnicaHome "runtimes/$($entry.Name)/$($artifact.version)--$($target.asset.sha256)/win-x64"
        $ready = Get-Content -LiteralPath (Join-Path $cache '.ready.json') -Raw | ConvertFrom-Json
        if ($ready.artifact -ne $entry.Name -or $ready.version -ne $artifact.version -or $ready.assetSha256 -ne $target.asset.sha256) {
            throw "Wrong cached runtime: $($entry.Name)"
        }
        foreach ($file in $target.files) {
            $path = Join-Path $cache $file.path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing runtime file: $path" }
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.sha256) { throw "Runtime hash mismatch: $path" }
        }
    }
}
try {
    $env:USERPROFILE = $root
    $env:PSModuleAnalysisCachePath = Join-Path $root 'ModuleAnalysisCache'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $adapter install -Version stable
    if ($LASTEXITCODE -ne 0) { throw 'Stable installation failed' }
    $unicaHome = Join-Path $root '.cursor/unica'
    $activeFile = Join-Path $unicaHome 'active.json'
    $stable = Get-Content -LiteralPath $activeFile -Raw | ConvertFrom-Json
    $state = Get-Content -LiteralPath (Join-Path $unicaHome "installs/$($stable.current)/.unica-cursor-state.json") -Raw | ConvertFrom-Json
    if ($state.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Stable selection installed a pre-release' }
    Assert-Runtimes $unicaHome $stable.current

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $adapter update -Version v0.15.0-rc.1
    if ($LASTEXITCODE -ne 0) { throw 'RC installation failed' }
    $rc = Get-Content -LiteralPath $activeFile -Raw | ConvertFrom-Json
    $state = Get-Content -LiteralPath (Join-Path $unicaHome "installs/$($rc.current)/.unica-cursor-state.json") -Raw | ConvertFrom-Json
    if ($state.version -ne '0.15.0-rc.1' -or $state.requestedRef -ne 'v0.15.0-rc.1') { throw 'Wrong RC installed' }
    if ($rc.previous -ne $stable.current) { throw 'Stable installation was not kept for rollback' }
    if (-not (Test-Path -LiteralPath (Join-Path $unicaHome "installs/$($rc.current)/cursor/unica-cursor-shim.exe"))) { throw 'Cursor shim missing' }
    Assert-Runtimes $unicaHome $rc.current

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $adapter rollback
    if ($LASTEXITCODE -ne 0) { throw 'Rollback failed' }
    $rolledBack = Get-Content -LiteralPath $activeFile -Raw | ConvertFrom-Json
    if ($rolledBack.current -ne $stable.current -or $rolledBack.previous -ne $rc.current) { throw 'Rollback selected the wrong installation' }
    Write-Host 'live stable -> RC -> rollback: ok'
}
finally {
    $env:USERPROFILE = $originalProfile
    $env:PSModuleAnalysisCachePath = $originalModuleCache
    # The exact disposable path was created above; never remove a user profile.
    if ((Split-Path -Parent ([IO.Path]::GetFullPath($root))) -ne ([IO.Path]::GetTempPath()).TrimEnd('\')) { throw 'Unexpected test cleanup path' }
    Remove-Item -LiteralPath $root -Recurse -Force
}
