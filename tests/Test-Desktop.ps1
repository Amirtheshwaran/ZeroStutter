# Compiles the real GUI and exercises nonvisual checks without tuning a game.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ZeroStutter-DesktopTest-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
try {
    $executable = Join-Path $testRoot 'ZeroStutter.exe'
    & (Join-Path $repoRoot 'Build-Desktop.ps1') -OutputPath $executable
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Desktop build produced no executable.' }
    $binary = [IO.File]::ReadAllBytes($executable)
    if ($binary[0] -ne 0x4D -or $binary[1] -ne 0x5A) { throw 'Desktop artifact is not a Windows executable.' }
    $pe = [BitConverter]::ToInt32($binary, 0x3C)
    if ([BitConverter]::ToUInt16($binary, $pe + 4) -ne 0x8664) { throw 'Desktop artifact must target x64.' }
    if ([BitConverter]::ToUInt16($binary, $pe + 24 + 68) -ne 2) { throw 'Desktop artifact must use the Windows GUI subsystem.' }
    $child = Start-Process -FilePath $executable -ArgumentList '--self-test' -WindowStyle Hidden -PassThru
    try {
        if (-not $child.WaitForExit(15000)) { $child.Kill(); throw 'Desktop self-test timed out.' }
        if ($child.ExitCode -ne 0) { throw "Desktop self-test failed: $($child.ExitCode)" }
    } finally { $child.Dispose() }
    $rejected = $false
    try { & (Join-Path $repoRoot 'Build-Desktop.ps1') -OutputPath $executable } catch { $rejected = $true }
    if (-not $rejected) { throw 'Desktop builder overwrote an existing executable.' }

    $packageDirectory = Join-Path $testRoot 'package'
    & (Join-Path $repoRoot 'Build-Package.ps1') -OutputDirectory $packageDirectory
    $archivePath = Join-Path $packageDirectory 'ZeroStutter.zip'
    $expectedHash = ((Get-Content -LiteralPath (Join-Path $packageDirectory 'SHA256SUMS.txt') -Raw).Trim() -split '\s+')[0]
    if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ine $expectedHash) { throw 'Package checksum is incorrect.' }
    $expanded = Join-Path $testRoot 'expanded'
    Expand-Archive -LiteralPath $archivePath -DestinationPath $expanded
    foreach ($required in @('ZeroStutter.exe', 'Build-Desktop.ps1', 'Build-Package.ps1', 'src\ZeroStutter.Desktop.cs', 'tests\Validate-Project.ps1', 'LICENSE', 'docs\testing\2026-10-02-cyberpunk.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $expanded $required) -PathType Leaf)) { throw "Package omitted $required." }
    }
    foreach ($excluded in @('captures', 'dist', '.git')) {
        if (Test-Path -LiteralPath (Join-Path $expanded $excluded)) { throw "Package contains private or generated directory $excluded." }
    }
    $manifest = Get-Content -LiteralPath (Join-Path $expanded 'build-manifest.json') -Raw | ConvertFrom-Json
    $manifestPaths = @{}
    foreach ($entry in $manifest.Files) {
        if ($manifestPaths.ContainsKey([string]$entry.Path)) { throw 'Package manifest contains duplicate paths.' }
        $manifestPaths[[string]$entry.Path] = $true
        $file = Join-Path $expanded ([string]$entry.Path)
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Manifest file is absent: $($entry.Path)" }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $entry.SHA256) { throw "Manifest hash mismatch: $($entry.Path)" }
    }
    if ($manifestPaths.Count -ne @(Get-ChildItem -LiteralPath $expanded -File -Recurse | Where-Object Name -ne 'build-manifest.json').Count) {
        throw 'Package manifest does not account for every packaged file.'
    }
    $rejected = $false
    try { & (Join-Path $repoRoot 'Build-Package.ps1') -OutputDirectory $packageDirectory } catch { $rejected = $true }
    if (-not $rejected) { throw 'Package builder overwrote an existing archive.' }

    # A release ZIP includes sufficient source to rebuild without Git metadata.
    $rebuiltDirectory = Join-Path $testRoot 'rebuilt'
    & (Join-Path $expanded 'Build-Package.ps1') -OutputDirectory $rebuiltDirectory
    $rebuiltStage = @(Get-ChildItem -LiteralPath $rebuiltDirectory -Directory -Filter 'package-*')[0].FullName
    $rebuiltManifest = Get-Content -LiteralPath (Join-Path $rebuiltStage 'build-manifest.json') -Raw | ConvertFrom-Json
    if ($rebuiltManifest.SourceCommit -ne 'unknown' -or $null -ne $rebuiltManifest.SourceDirty) { throw 'A ZIP rebuild claimed unverifiable Git provenance.' }
    Write-Host 'Desktop checks passed: x64 GUI, self-test, protected outputs, package hashes, and source ZIP rebuild.'
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('ZeroStutter-DesktopTest-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
