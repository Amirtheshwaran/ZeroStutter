# Remove only the files installed by ZeroStutter.
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1

[CmdletBinding()]
param([switch]$SkipShortcut)

$ErrorActionPreference = 'Stop'
$operationLock = New-Object System.Threading.Mutex($false, 'Local\ZeroStutter.GameSession.v1')
$operationHeld = $false
try {
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
        if ($shortcut.Arguments -like ('*' + $installDir + '*')) {
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
foreach ($relativePath in @('Start-ZeroStutterSession.ps1', 'Restore-ZeroStutterSession.ps1', 'Launch-ZeroStutter.ps1', 'Start-ZeroStutter.cmd', 'Measure-ZeroStutter.ps1', 'src\ZeroStutter.Native.cs', 'src\ZeroStutter.Tuning.psm1', 'src\ZeroStutter.Power.psm1', 'src\ZeroStutter.Recovery.psm1', 'src\ZeroStutter.Measurement.psm1', 'LICENSE', 'README.md')) {
    $installedFiles += Join-Path $installDir $relativePath
}
foreach ($path in $installedFiles) {
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
}
foreach ($directory in @((Join-Path $installDir 'src'), (Join-Path $installDir 'schema'), $installDir)) {
    if (Test-Path -LiteralPath $directory -PathType Container) {
        $children = @(Get-ChildItem -LiteralPath $directory -Force)
        if ($children.Count -eq 0) { Remove-Item -LiteralPath $directory -Force }
    }
}
Write-Host "ZeroStutter program files removed from $installDir. User reports, backups, and unknown files were preserved."
} finally {
    if ($operationHeld) { $operationLock.ReleaseMutex() }
    $operationLock.Dispose()
}
