#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$ApplyProfilePriorities,
    [ValidateRange(1, 60)][int]$RefreshSeconds = 2,
    [string]$ProfilePath = ''
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProfilePath)) { $ProfilePath = Join-Path $PSScriptRoot 'profiles.json' }
if ($env:OS -ne 'Windows_NT') { throw 'ZeroStutter supports Windows 10 and Windows 11 only.' }
if ($Once -and $ApplyProfilePriorities) {
    throw '-Once is read-only and cannot be combined with -ApplyProfilePriorities.'
}
if (-not $Once) {
    $interactiveConsole = $false
    try {
        $interactiveConsole = [Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected
    } catch { }
    if (-not $interactiveConsole) {
        throw 'The live monitor requires an interactive console so you can exit normally. Use -Once for a read-only scan.'
    }
}
$modulePath = Join-Path $PSScriptRoot 'src\ZeroStutter.Core.psm1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw "Core module not found: $modulePath" }
Import-Module -Name $modulePath -Force
$profiles = @(Get-ZeroStutterProfiles -Path $ProfilePath)
$managedProcesses = @{}

function Get-MemorySnapshot {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -Property FreePhysicalMemory, TotalVisibleMemorySize -ErrorAction Stop
        [pscustomobject]@{
            FreeGb  = [math]::Round(([double]$os.FreePhysicalMemory * 1KB) / 1GB, 2)
            TotalGb = [math]::Round(([double]$os.TotalVisibleMemorySize * 1KB) / 1GB, 2)
        }
    } catch { [pscustomobject]@{ FreeGb = $null; TotalGb = $null } }
}

function Get-CurrentTargets {
    $processes = @(Get-Process -ErrorAction SilentlyContinue)
    return @(Get-ZeroStutterTargetProcesses -Profiles $profiles -Processes $processes)
}

function Update-Targets {
    param([object[]]$Targets)
    foreach ($target in $Targets) {
        if ($target.ConfiguredPriority -eq 'Observe') {
            $target.Status = 'Observe only'
        } elseif (-not $ApplyProfilePriorities) {
            $target.Status = 'Profile opts in; use -ApplyProfilePriorities to apply'
        }
    }
    if ($ApplyProfilePriorities) {
        foreach ($action in @(Set-ZeroStutterProfilePriorities -Targets $Targets -ManagedProcesses $managedProcesses)) {
            Write-Host "[+] $action" -ForegroundColor Green
        }
        Remove-ZeroStutterExitedProcesses -ManagedProcesses $managedProcesses
    }
}

function Show-Dashboard {
    param([object[]]$Targets)
    Clear-Host
    Write-Host '============================================================================' -ForegroundColor Cyan
    Write-Host '  ZeroStutter | Windows process monitor' -ForegroundColor Yellow
    Write-Host '============================================================================' -ForegroundColor Cyan
    Write-Host '  Read-only by default. No timer, memory, affinity, registry, or power-plan changes.' -ForegroundColor DarkGray
    $memory = Get-MemorySnapshot
    if ($null -ne $memory.FreeGb) {
        Write-Host ("  Free RAM (Windows WMI): {0} GB of {1} GB" -f $memory.FreeGb, $memory.TotalGb)
    } else { Write-Host '  Free RAM: unavailable' }
    Write-Host ("  Profiles loaded: {0} | Matching processes: {1}" -f $profiles.Count, $Targets.Count)
    if ($ApplyProfilePriorities) {
        Write-Host ("  Temporary priority changes active: {0}" -f $managedProcesses.Count) -ForegroundColor Yellow
    }
    Write-Host ''
    if ($Targets.Count -eq 0) {
        Write-Host '  No profile-listed processes are running.' -ForegroundColor DarkGray
    } else {
        $Targets | Select-Object ProfileName, ProcessName, ProcessId, PriorityClass, Status | Format-Table -AutoSize
    }
    Write-Host '  Q: quit and restore managed priorities | Ctrl+C: stop and restore in finally' -ForegroundColor Gray
    Write-Host '============================================================================' -ForegroundColor Cyan
}

if ($Once) {
    $targets = Get-CurrentTargets
    Update-Targets -Targets $targets
    Write-Host ("Loaded {0} profiles; found {1} matching process(es)." -f $profiles.Count, $targets.Count)
    if ($targets.Count -gt 0) {
        $targets | Select-Object ProfileName, ProcessName, ProcessId, PriorityClass, Status | Format-Table -AutoSize
    }
    return
}
if ($ApplyProfilePriorities) {
    Write-Warning 'Only profiles set to AboveNormal will be changed. Do not use this with software whose rules prohibit process-tuning utilities. Normal Q/Ctrl+C exit restores the original value; forced termination can leave a target process AboveNormal until it exits.'
}

try {
    while ($true) {
        $targets = Get-CurrentTargets
        Update-Targets -Targets $targets
        Show-Dashboard -Targets $targets
        try {
            if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq [ConsoleKey]::Q) { break }
        } catch {
            # Without an interactive console, Ctrl+C remains the exit path.
        }
        Start-Sleep -Seconds $RefreshSeconds
    }
} finally {
    if ($ApplyProfilePriorities -and $managedProcesses.Count -gt 0) {
        Write-Host ''
        foreach ($result in @(Restore-ZeroStutterPriorities -ManagedProcesses $managedProcesses)) {
            Write-Host "[restore] $result" -ForegroundColor Yellow
        }
    }
    Remove-Module ZeroStutter.Core -ErrorAction SilentlyContinue
}
