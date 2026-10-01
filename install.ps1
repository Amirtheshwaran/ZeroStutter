# Install ZeroStutter from a local checkout. No network download or elevation is needed.
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

[CmdletBinding()]
param([switch]$SkipShortcut)

$ErrorActionPreference = 'Stop'
$sourceDir = $PSScriptRoot
$requiredFiles = @(
    (Join-Path $sourceDir 'ZeroStutter.ps1'),
    (Join-Path $sourceDir 'profiles.json'),
    (Join-Path $sourceDir 'src\ZeroStutter.Core.psm1'),
    (Join-Path $sourceDir 'schema\profiles.schema.json'),
    (Join-Path $sourceDir 'uninstall.ps1')
)
foreach ($path in $requiredFiles) {
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
$null = New-Item -ItemType Directory -Path (Join-Path $installDir 'src') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $installDir 'schema') -Force
Copy-IfDifferent (Join-Path $sourceDir 'ZeroStutter.ps1') $installDir
Copy-IfDifferent (Join-Path $sourceDir 'src\ZeroStutter.Core.psm1') (Join-Path $installDir 'src')
Copy-IfDifferent (Join-Path $sourceDir 'schema\profiles.schema.json') (Join-Path $installDir 'schema')
Copy-IfDifferent (Join-Path $sourceDir 'uninstall.ps1') $installDir

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
        $shortcut.TargetPath = 'powershell.exe'
        $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $installDir 'ZeroStutter.ps1') + '"'
        $shortcut.WorkingDirectory = $installDir
        $shortcut.Description = 'ZeroStutter Windows process monitor'
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
Write-Host 'Run ZeroStutter and use Q to exit. It does not require administrator rights.'
