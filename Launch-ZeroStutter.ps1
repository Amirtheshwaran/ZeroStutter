#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Write-Host 'ZeroStutter | Measure and tune frame pacing' -ForegroundColor Cyan
Write-Host '1. Start a game session (priority + HighQoS)'
Write-Host '2. Monitor processes without tuning'
Write-Host '3. Show CPU topology'
Write-Host '4. Recover an interrupted session'
Write-Host 'Q. Quit'
try {
    switch (Read-Host 'Choose') {
        '1' {
            Write-Host 'Start your game first. Find its executable name in Task Manager > Details.'
            $gameName = Read-Host 'Game executable (example: cs2.exe)'
            $cpuPolicy = 'Default'
            $unpark = $false
            if ((Read-Host 'Try performance cores only on a hybrid CPU? (y/N)') -eq 'y') { $cpuPolicy = 'Performance' }
            if ((Read-Host 'Try AC core unparking? More power/heat; restores afterward (y/N)') -eq 'y') { $unpark = $true }
            & (Join-Path $PSScriptRoot 'Start-ZeroStutterSession.ps1') -Game $gameName -CpuPolicy $cpuPolicy -UnparkCores:$unpark
        }
        '2' { & (Join-Path $PSScriptRoot 'ZeroStutter.ps1') }
        '3' { & (Join-Path $PSScriptRoot 'ZeroStutter.ps1') -Topology | Format-List }
        '4' { & (Join-Path $PSScriptRoot 'ZeroStutter.ps1') -Recover }
        'q' { return }
        default { throw 'Choose 1, 2, 3, 4, or Q.' }
    }
} catch { Write-Host $_.Exception.Message -ForegroundColor Red }
$null = Read-Host 'Press Enter to close'
