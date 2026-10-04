# Remove only the files installed by ZeroStutter.
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1

[CmdletBinding()]
param([switch]$SkipShortcut)

$ErrorActionPreference = 'Stop'
$desktopLock = New-Object System.Threading.Mutex($false, 'Local\ZeroStutter.Desktop.v1')
$desktopHeld = $false
$operationLock = New-Object System.Threading.Mutex($false, 'Local\ZeroStutter.GameSession.v1')
$operationHeld = $false
try {
    try { $desktopHeld = $desktopLock.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $desktopHeld = $true }
    if (-not $desktopHeld) { throw 'Close the ZeroStutter desktop app before uninstalling.' }
    try { $operationHeld = $operationLock.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $operationHeld = $true }
    if (-not $operationHeld) { throw 'End the running ZeroStutter game session before uninstalling.' }
$installDir = Join-Path $env:LOCALAPPDATA 'ZeroStutter'
$stateDirectory = Join-Path $installDir 'State'
if (Test-Path -LiteralPath (Join-Path $installDir 'Restore-ZeroStutterSession.ps1')) {
    & (Join-Path $installDir 'Restore-ZeroStutterSession.ps1') -StateDirectory $stateDirectory
}

if (-not $SkipShortcut) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $shortcutPath = Join-Path $desktop 'ZeroStutter.lnk'
    if (Test-Path -LiteralPath $shortcutPath) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        if ($shortcut.Arguments -like ('*' + $installDir + '*') -or $shortcut.TargetPath -ieq (Join-Path $installDir 'ZeroStutter.exe')) {
            Remove-Item -LiteralPath $shortcutPath -Force
            Write-Host 'Removed the desktop shortcut.'
        } else { Write-Host 'Preserved an unrelated desktop shortcut.' }
    }
}

$installedFiles = @(
    (Join-Path $installDir 'ZeroStutter.ps1'),
    (Join-Path $installDir 'profiles.json'),
    (Join-Path $installDir 'uninstall.ps1'),
    (Join-Path $installDir 'src\ZeroStutter.Core.psm1'),
    (Join-Path $installDir 'schema\profiles.schema.json')
)
foreach ($relativePath in @('ZeroStutter.exe', 'Build-Desktop.ps1', 'src\ZeroStutter.Desktop.cs', 'CONTRIBUTING.md', 'ROADMAP.md', 'Start-ZeroStutterSession.ps1', 'Restore-ZeroStutterSession.ps1', 'Launch-ZeroStutter.ps1', 'Start-ZeroStutter.cmd', 'Measure-ZeroStutter.ps1', 'src\ZeroStutter.Native.cs', 'src\ZeroStutter.Tuning.psm1', 'src\ZeroStutter.Power.psm1', 'src\ZeroStutter.Recovery.psm1', 'src\ZeroStutter.Measurement.psm1', 'LICENSE', 'README.md', 'docs\testing\2026-10-02-cyberpunk.md', 'docs\testing\2026-10-02-cyberpunk.json')) {
    $installedFiles += Join-Path $installDir $relativePath
}
# Profiles are editable user data. Keep a unique copy before removing the active
# filename so a later reinstall can start clean without losing custom entries.
$profilesPath = Join-Path $installDir 'profiles.json'
if (Test-Path -LiteralPath $profilesPath -PathType Leaf) {
    $profileBackup = $profilesPath + '.backup-uninstall-' + [guid]::NewGuid().ToString('N')
    Copy-Item -LiteralPath $profilesPath -Destination $profileBackup
    Write-Host "Preserved profiles in $profileBackup"
}
foreach ($path in $installedFiles) {
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
}
foreach ($directory in @((Join-Path $installDir 'src'), (Join-Path $installDir 'schema'), (Join-Path $installDir 'docs\testing'), (Join-Path $installDir 'docs'), $installDir)) {
    if (Test-Path -LiteralPath $directory -PathType Container) {
        $children = @(Get-ChildItem -LiteralPath $directory -Force)
        if ($children.Count -eq 0) { Remove-Item -LiteralPath $directory -Force }
    }
}
Write-Host "ZeroStutter program files removed from $installDir. User reports, backups, and unknown files were preserved."
} finally {
    if ($operationHeld) { $operationLock.ReleaseMutex() }
    $operationLock.Dispose()
    if ($desktopHeld) { $desktopLock.ReleaseMutex() }
    $desktopLock.Dispose()
}
