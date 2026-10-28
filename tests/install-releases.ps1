# Live GitHub integration check; installs into a disposable USERPROFILE.
$ErrorActionPreference = 'Stop'
$adapter = Join-Path (Split-Path -Parent $PSScriptRoot) 'unica-cursor.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('unica-release-test-' + [guid]::NewGuid().ToString('N'))
$originalProfile = $env:USERPROFILE
$originalModuleCache = $env:PSModuleAnalysisCachePath
New-Item -ItemType Directory -Path $root | Out-Null
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

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $adapter update -Version v0.15.0-rc.1
    if ($LASTEXITCODE -ne 0) { throw 'RC installation failed' }
    $rc = Get-Content -LiteralPath $activeFile -Raw | ConvertFrom-Json
    $state = Get-Content -LiteralPath (Join-Path $unicaHome "installs/$($rc.current)/.unica-cursor-state.json") -Raw | ConvertFrom-Json
    if ($state.version -ne '0.15.0-rc.1' -or $state.requestedRef -ne 'v0.15.0-rc.1') { throw 'Wrong RC installed' }
    if ($rc.previous -ne $stable.current) { throw 'Stable installation was not kept for rollback' }
    if (-not (Test-Path -LiteralPath (Join-Path $unicaHome "installs/$($rc.current)/cursor/unica-cursor-shim.exe"))) { throw 'Cursor shim missing' }

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
