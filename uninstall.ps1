# Remove only the files installed by ZeroStutter.
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1

[CmdletBinding()]
param([switch]$SkipShortcut)

$ErrorActionPreference = 'Continue'
$installDir = Join-Path $env:LOCALAPPDATA 'ZeroStutter'

if (-not $SkipShortcut) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $shortcutPath = Join-Path $desktop 'ZeroStutter.lnk'
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
        Write-Host 'Removed the desktop shortcut.'
    }
}

$installedFiles = @(
    (Join-Path $installDir 'ZeroStutter.ps1'),
    (Join-Path $installDir 'profiles.json'),
    (Join-Path $installDir 'uninstall.ps1'),
    (Join-Path $installDir 'src\ZeroStutter.Core.psm1'),
    (Join-Path $installDir 'schema\profiles.schema.json')
)
foreach ($path in $installedFiles) {
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
}
foreach ($directory in @((Join-Path $installDir 'src'), (Join-Path $installDir 'schema'), $installDir)) {
    if (Test-Path -LiteralPath $directory -PathType Container) {
        $children = @(Get-ChildItem -LiteralPath $directory -Force)
        if ($children.Count -eq 0) { Remove-Item -LiteralPath $directory -Force }
    }
}
Write-Host "ZeroStutter files removed from $installDir. No system power, registry, timer, or affinity settings were changed."
