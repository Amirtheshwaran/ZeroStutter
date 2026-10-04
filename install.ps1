# Install ZeroStutter from a local checkout. No network download or elevation is needed.
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

[CmdletBinding()]
param([switch]$SkipShortcut)

$ErrorActionPreference = 'Stop'
$desktopLock = New-Object System.Threading.Mutex($false, 'Local\ZeroStutter.Desktop.v1')
$desktopHeld = $false
$operationLock = New-Object System.Threading.Mutex($false, 'Local\ZeroStutter.GameSession.v1')
$operationHeld = $false
try {
    try { $desktopHeld = $desktopLock.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $desktopHeld = $true }
    if (-not $desktopHeld) { throw 'Close the ZeroStutter desktop app before installing or updating.' }
    try { $operationHeld = $operationLock.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $operationHeld = $true }
    if (-not $operationHeld) { throw 'End the running ZeroStutter game session before installing or updating.' }
    $existingRecovery = Join-Path $env:LOCALAPPDATA 'ZeroStutter\Restore-ZeroStutterSession.ps1'
    if (Test-Path -LiteralPath $existingRecovery) { & $existingRecovery }
$sourceDir = $PSScriptRoot
$packageFiles = @(
    'ZeroStutter.ps1', 'Start-ZeroStutterSession.ps1', 'Restore-ZeroStutterSession.ps1',
    'Launch-ZeroStutter.ps1', 'Start-ZeroStutter.cmd', 'Measure-ZeroStutter.ps1',
    'src\ZeroStutter.Core.psm1', 'src\ZeroStutter.Native.cs', 'src\ZeroStutter.Tuning.psm1',
    'src\ZeroStutter.Power.psm1', 'src\ZeroStutter.Recovery.psm1', 'src\ZeroStutter.Measurement.psm1',
    'src\ZeroStutter.Desktop.cs', 'Build-Desktop.ps1',
    'schema\profiles.schema.json', 'uninstall.ps1', 'LICENSE', 'README.md', 'CONTRIBUTING.md', 'ROADMAP.md',
    'docs\testing\2026-10-02-cyberpunk.md', 'docs\testing\2026-10-02-cyberpunk.json'
)
foreach ($relativePath in @($packageFiles) + @('profiles.json')) {
    $path = Join-Path $sourceDir $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required project file missing: $path" }
}

function Copy-IfDifferent {
    param([string]$Source, [string]$Destination)
    $destinationFile = $Destination
    if (Test-Path -LiteralPath $Destination -PathType Container) {
        $destinationFile = Join-Path $Destination ([IO.Path]::GetFileName($Source))
    }
    if ([IO.Path]::GetFullPath($Source) -ine [IO.Path]::GetFullPath($destinationFile)) {
        Copy-Item -LiteralPath $Source -Destination $destinationFile -Force
    }
}

$installDir = Join-Path $env:LOCALAPPDATA 'ZeroStutter'
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
$sourceExecutable = Join-Path $sourceDir 'ZeroStutter.exe'
if (-not (Test-Path -LiteralPath $sourceExecutable -PathType Leaf)) {
    $sourceExecutable = Join-Path ([IO.Path]::GetTempPath()) ('ZeroStutter-build-' + [guid]::NewGuid().ToString('N') + '.exe')
    try {
        & (Join-Path $sourceDir 'Build-Desktop.ps1') -OutputPath $sourceExecutable
        Copy-IfDifferent $sourceExecutable (Join-Path $installDir 'ZeroStutter.exe')
    } finally {
        if (Test-Path -LiteralPath $sourceExecutable -PathType Leaf) { Remove-Item -LiteralPath $sourceExecutable -Force }
    }
} else { Copy-IfDifferent $sourceExecutable (Join-Path $installDir 'ZeroStutter.exe') }
$null = New-Item -ItemType Directory -Path (Join-Path $installDir 'src') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $installDir 'schema') -Force
foreach ($relativePath in $packageFiles) {
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent (Join-Path $installDir $relativePath)) -Force
    Copy-IfDifferent (Join-Path $sourceDir $relativePath) (Join-Path $installDir $relativePath)
}

$profileDestination = Join-Path $installDir 'profiles.json'
$profilePreserved = $false
if (Test-Path -LiteralPath $profileDestination -PathType Leaf) {
    try {
        Import-Module -Name (Join-Path $installDir 'src\ZeroStutter.Core.psm1') -Force
        $null = @(Get-ZeroStutterProfiles -Path $profileDestination)
        $profilePreserved = $true
    } catch {
        $backupPath = $profileDestination + '.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
        Copy-Item -LiteralPath $profileDestination -Destination $backupPath -Force
        Copy-IfDifferent (Join-Path $sourceDir 'profiles.json') $profileDestination
        Write-Warning "The installed profiles used an older or invalid format. A copy was saved to $backupPath; review it and merge any custom entries."
    } finally {
        Remove-Module ZeroStutter.Core -ErrorAction SilentlyContinue
    }
} else {
    Copy-IfDifferent (Join-Path $sourceDir 'profiles.json') $profileDestination
}

$shortcutCreated = $false
if (-not $SkipShortcut) {
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $shortcutPath = Join-Path $desktop 'ZeroStutter.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        if ((Test-Path -LiteralPath $shortcutPath) -and $shortcut.Arguments -notlike ('*' + $installDir + '*') -and $shortcut.TargetPath -ine (Join-Path $installDir 'ZeroStutter.exe')) { throw 'An unrelated ZeroStutter shortcut already exists; it was preserved.' }
        $shortcut.TargetPath = Join-Path $installDir 'ZeroStutter.exe'
        $shortcut.Arguments = ''
        $shortcut.IconLocation = $shortcut.TargetPath
        $shortcut.WorkingDirectory = $installDir
        $shortcut.Description = 'ZeroStutter frame pacing toolkit'
        $shortcut.Save()
        $shortcutCreated = $true
    } catch {
        Write-Warning "Could not create a desktop shortcut: $($_.Exception.Message)"
    }
}

Write-Host "Installed to $installDir"
if ($profilePreserved) { Write-Host 'Kept the existing valid profiles.json.' }
if ($shortcutCreated) { Write-Host 'Created a desktop shortcut. No process tuning starts automatically.' }
if ($SkipShortcut) { Write-Host 'Desktop shortcut creation was skipped.' }
Write-Host 'Launch ZeroStutter.exe or the desktop shortcut. Select a running game, then start a session.'
} finally {
    if ($operationHeld) { $operationLock.ReleaseMutex() }
    $operationLock.Dispose()
    if ($desktopHeld) { $desktopLock.ReleaseMutex() }
    $desktopLock.Dispose()
}
