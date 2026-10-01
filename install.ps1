# Install ZeroStutter from a local checkout. No network download or elevation is needed.
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

[CmdletBinding()]
param([switch]$SkipShortcut)

$ErrorActionPreference = 'Stop'
$operationLock = New-Object System.Threading.Mutex($false, 'Local\ZeroStutter.GameSession.v1')
$operationHeld = $false
try {
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
    'schema\profiles.schema.json', 'uninstall.ps1', 'LICENSE', 'README.md'
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
$null = New-Item -ItemType Directory -Path (Join-Path $installDir 'src') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $installDir 'schema') -Force
foreach ($relativePath in $packageFiles) {
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
        $shortcut.TargetPath = 'powershell.exe'
        if ((Test-Path -LiteralPath $shortcutPath) -and $shortcut.Arguments -notlike ('*' + $installDir + '*')) { throw 'An unrelated ZeroStutter shortcut already exists; it was preserved.' }
        $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $installDir 'Launch-ZeroStutter.ps1') + '"'
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
Write-Host 'Launch Start-ZeroStutter.cmd or the desktop shortcut. Choose a game session or monitor.'
} finally {
    if ($operationHeld) { $operationLock.ReleaseMutex() }
    $operationLock.Dispose()
}
