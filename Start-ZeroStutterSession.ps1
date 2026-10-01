#Requires -Version 5.1
<#
.SYNOPSIS
Runs a reversible tuning session for one already-running game or application.
.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-ZeroStutterSession.ps1 -Game cs2
#>
[CmdletBinding(DefaultParameterSetName = 'Name')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Name')][ValidateNotNullOrEmpty()][string]$Game,
    [Parameter(Mandatory, ParameterSetName = 'Id')][ValidateRange(1, 2147483647)][int]$ProcessId,
    [ValidateSet('Observe', 'AboveNormal')][string]$Priority = 'AboveNormal',
    [ValidateSet('Default', 'Performance')][string]$CpuPolicy = 'Default',
    [switch]$DisableHighQoS,
    [switch]$UnparkCores,
    [switch]$Headless,
    [ValidateRange(0, 86400)][int]$Seconds = 0,
    [string]$StateDirectory = (Join-Path $env:LOCALAPPDATA 'ZeroStutter\State'),
    [string]$ReportPath
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'ZeroStutter sessions require Windows 10/11.' }
if (-not $Headless -and [Console]::IsInputRedirected) {
    throw 'Use -Headless in a redirected console. The session ends when the game exits, or after -Seconds.'
}
if ($ReportPath) {
    $ReportPath = [IO.Path]::GetFullPath($ReportPath)
    if (Test-Path -LiteralPath $ReportPath) { throw "Report already exists: $ReportPath" }
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $ReportPath) -PathType Container)) { throw 'Report parent directory does not exist.' }
}

$targetProcess = $null
$tuningState = $null
$powerState = $null
$managed = @{}
$lock = New-Object System.Threading.Mutex($false, 'Local\ZeroStutter.GameSession.v1')
$lockHeld = $false
$started = [DateTime]::UtcNow
$stopResults = @()
$sessionError = $null
$cleanupFailed = $false
$guardian = $null
$journalCreated = $false
$journalPath = Join-Path $StateDirectory 'session.json'
$sessionId = [guid]::NewGuid().ToString('N')
$readyPath = Join-Path $StateDirectory ($sessionId + '.ready')
$report = [ordered]@{ Version = 1; StartedUtc = $started.ToString('o'); ProcessId = 0; ProcessName = ''; RequestedPriority = $Priority; CpuPolicy = $CpuPolicy; HighQoS = (-not $DisableHighQoS); UnparkCores = [bool]$UnparkCores }
try {
    try { $lockHeld = $lock.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $lockHeld = $true }
    if (-not $lockHeld) { throw 'A ZeroStutter game session is already running in this Windows session. Stop it before starting another.' }
    if (Test-Path -LiteralPath $journalPath) {
        Import-Module (Join-Path $PSScriptRoot 'src\ZeroStutter.Recovery.psm1') -Force
        Repair-ZeroStutterSession -StateDirectory $StateDirectory -AllowCurrentOwner | Out-Host
    }

    if ($PSCmdlet.ParameterSetName -eq 'Name') {
        if ($Game -match '[\\/:*?\[\]]' -or [string]::IsNullOrWhiteSpace($Game)) { throw '-Game expects an exact executable name such as cs2 or cs2.exe.' }
        $processName = $Game -replace '\.exe$', ''
        $matches = @()
        foreach ($candidate in @(Get-Process -ErrorAction SilentlyContinue)) {
            if ($candidate.ProcessName -ieq $processName) { $matches += $candidate } else { $candidate.Dispose() }
        }
        if ($matches.Count -ne 1) {
            $matchingIds = ($matches | ForEach-Object { $_.Id }) -join ', '
            foreach ($candidate in $matches) { $candidate.Dispose() }
            if ($matches.Count -eq 0) { throw "Start '$Game' first, then run this command again. Use the game executable name shown in Task Manager, not its launcher." }
            throw "More than one '$Game' is running (PIDs: $matchingIds). Select one with -ProcessId."
        }
        $targetProcess = $matches[0]
    } else { $targetProcess = Get-Process -Id $ProcessId -ErrorAction Stop }
    if ($targetProcess.Id -eq $PID -or $targetProcess.Id -eq 4 -or $targetProcess.SessionId -eq 0) {
        throw 'Select a game/application in your desktop session; ZeroStutter does not tune itself or system services.'
    }
    $report.ProcessId = $targetProcess.Id
    $report.ProcessName = $targetProcess.ProcessName
    $creationTime = $targetProcess.StartTime.ToUniversalTime()

    Import-Module (Join-Path $PSScriptRoot 'src\ZeroStutter.Core.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'src\ZeroStutter.Tuning.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'src\ZeroStutter.Recovery.psm1') -Force
    # A failed native operation rolls back before throwing. Performance policy
    # refuses homogeneous/ambiguous topology instead of inventing a CPU mask.
    $tuningState = New-ZeroStutterProcessTuningState -ProcessId $targetProcess.Id -CpuPolicy $CpuPolicy -HighQoS:(-not $DisableHighQoS)
    $targetProcess.Refresh()
    $originalPriority = [string]$targetProcess.PriorityClass
    $priorityWillChange = $Priority -eq 'AboveNormal' -and $originalPriority -in @('Normal', 'BelowNormal')
    $ownerProcess = Get-Process -Id $PID
    try {
        $journal = [ordered]@{ Version = 1; Application = 'ZeroStutter.GameSession'; Owner = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; Machine = [Environment]::MachineName; SessionId = $sessionId; OwnerProcessId = $PID; OwnerCreationFileTime = $ownerProcess.StartTime.ToUniversalTime().ToFileTimeUtc(); Tuning = $tuningState; Priority = @{ Changed = $priorityWillChange; Original = $originalPriority; Applied = $Priority }; UnparkCores = [bool]$UnparkCores }
        $hostPath = $ownerProcess.Path
    } finally { $ownerProcess.Dispose() }
    $null = New-Item -ItemType Directory -Path $StateDirectory -Force
    Write-ZeroStutterSessionJournal -Path $journalPath -Journal $journal
    $journalCreated = $true
    $guardianScript = (Join-Path $PSScriptRoot 'Restore-ZeroStutterSession.ps1').Replace("'", "''")
    $guardianDirectory = ([IO.Path]::GetFullPath($StateDirectory)).Replace("'", "''")
    $guardianCommand = "& '$guardianScript' -StateDirectory '$guardianDirectory' -WatchOwner -SessionId '$sessionId'"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($guardianCommand))
    $guardian = Start-Process -FilePath $hostPath -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand) -PassThru -WindowStyle Hidden
    $readyTimeout = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $readyPath)) {
        if ($guardian.HasExited -or $readyTimeout.Elapsed.TotalSeconds -ge 10) { throw 'Recovery helper could not start. No session tuning has been applied.' }
        Start-Sleep -Milliseconds 100
    }
    Remove-Item -LiteralPath $readyPath -Force
    $null = Enable-ZeroStutterProcessTuning -State $tuningState
    $profile = [pscustomobject]@{ name = $targetProcess.ProcessName; executable = ($targetProcess.ProcessName + '.exe'); category = 'Session'; priorityClass = $Priority }
    $target = @(Get-ZeroStutterTargetProcesses -Profiles @($profile) -Processes @($targetProcess))
    $expectedPriorities = @{}
    $expectedPriorities[('{0}:{1}' -f $targetProcess.Id, $creationTime.Ticks)] = $originalPriority
    $priorityActions = @(Set-ZeroStutterProfilePriorities -Targets $target -ManagedProcesses $managed -ExpectedPriorities $expectedPriorities)
    if ($target[0].Status -eq 'Changed during setup') { throw 'Priority changed outside ZeroStutter during setup. Session cancelled; that priority was preserved.' }
    if ($target[0].Status -eq 'Skipped (exit/access)') { throw 'Could not apply the requested priority. The game exited or denied access.' }
    $report.PriorityStatus = $target[0].Status
    $report.NativeStatus = [string]$tuningState.Status
    if ($UnparkCores) {
        Import-Module (Join-Path $PSScriptRoot 'src\ZeroStutter.Power.psm1') -Force
        $powerState = Start-ZeroStutterPowerSession -StateDirectory $StateDirectory
        $report.OriginalPowerScheme = $powerState.OriginalScheme
        $report.SessionPowerScheme = $powerState.CloneScheme
    }
    $activeStarted = [DateTime]::UtcNow

    Write-Host ("ZeroStutter session: {0} (PID {1})" -f $report.ProcessName, $report.ProcessId) -ForegroundColor Cyan
    Write-Host ("Priority: {0} | CPU policy: {1} | HighQoS: {2} | Unpark AC: {3}" -f $report.PriorityStatus, $CpuPolicy, (-not $DisableHighQoS), [bool]$UnparkCores)
    Write-Host 'Measure the same game scene before/after with Measure-ZeroStutter.ps1.'
    if (-not $Headless) { Write-Host 'Q: end session and restore | The session also ends when this game process exits.' }
    $samples = @{}
    while ($true) {
        $targetProcess.Refresh()
        if ($targetProcess.HasExited) { $report.EndReason = 'TargetExited'; break }
        if ($targetProcess.StartTime.ToUniversalTime() -ne $creationTime) { throw 'The target process identity changed.' }
        if ($Seconds -gt 0 -and ([DateTime]::UtcNow - $activeStarted).TotalSeconds -ge $Seconds) { $report.EndReason = 'Duration'; break }
        if (-not $Headless) {
            if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq [ConsoleKey]::Q) { $report.EndReason = 'User'; break }
            Update-ZeroStutterTargetUsage -Targets $target -CpuSamples $samples
            Write-Host ("`rCPU {0,6}% | RAM {1,8} MB | Priority {2,-12} | elapsed {3,5:N0}s    " -f $target[0].CpuPercent, $target[0].WorkingSetMB, $targetProcess.PriorityClass, ([DateTime]::UtcNow - $started).TotalSeconds) -NoNewline
        }
        Start-Sleep -Milliseconds 500
    }
} catch {
    $sessionError = $_
    $report.Error = $_.Exception.Message
} finally {
    Write-Host ''
    # Restore every independent subsystem even if another cleanup fails.
    if ($null -ne $powerState) {
        try { $stopResults += @(Stop-ZeroStutterPowerSession -State $powerState) }
        catch { $cleanupFailed = $true; $stopResults += "Power restoration failed: $($_.Exception.Message). Run ZeroStutter.ps1 -Recover."; if ($null -eq $sessionError) { $sessionError = $_ } }
    }
    elseif ($journalCreated -and $UnparkCores -and (Test-Path -LiteralPath (Join-Path $StateDirectory 'power-session.json'))) {
        # Start may fail after changing the plan and retain a recovery journal.
        try {
            Import-Module (Join-Path $PSScriptRoot 'src\ZeroStutter.Power.psm1') -Force
            $stopResults += @(Repair-ZeroStutterPowerSession -StateDirectory $StateDirectory)
        } catch { $cleanupFailed = $true; $stopResults += $_.Exception.Message; if ($null -eq $sessionError) { $sessionError = $_ } }
    }
    if ($null -ne $tuningState) {
        try {
            $nativeResult = Stop-ZeroStutterProcessTuning -State $tuningState
            $stopResults += $nativeResult
            if (-not $nativeResult.Succeeded) { throw "Native restoration incomplete: $($nativeResult.Errors -join '; ')" }
        } catch { $cleanupFailed = $true; $stopResults += $_.Exception.Message; if ($null -eq $sessionError) { $sessionError = $_ } }
    }
    if ($managed.Count -gt 0) {
        try {
            $priorityResults = @(Restore-ZeroStutterPriorities -ManagedProcesses $managed)
            $stopResults += $priorityResults
            if (@($priorityResults | Where-Object { $_ -like '*could not restore*' }).Count -gt 0) { throw 'Priority cleanup incomplete. Recovery journal retained.' }
        } catch { $cleanupFailed = $true; $stopResults += $_.Exception.Message; if ($null -eq $sessionError) { $sessionError = $_ } }
    }
    if ($null -ne $targetProcess) { try { $targetProcess.Dispose() } catch { Write-Warning $_.Exception.Message } }
    if ($journalCreated -and -not $cleanupFailed) {
        try { Remove-Item -LiteralPath $journalPath -Force -ErrorAction Stop }
        catch { $stopResults += "Could not remove recovery journal: $($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $readyPath) { Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue }
    if ($null -ne $guardian) {
        try {
            if (-not (Test-Path -LiteralPath $journalPath)) {
                if (-not $guardian.WaitForExit(2500)) { $guardian.Kill() }
            }
        } catch { Write-Warning "Recovery helper cleanup: $($_.Exception.Message)" }
        finally { $guardian.Dispose() }
    }
    if ($lockHeld) { $lock.ReleaseMutex() }
    $lock.Dispose()
    $report.EndedUtc = [DateTime]::UtcNow.ToString('o')
    $report.Cleanup = $stopResults
    foreach ($result in $stopResults) {
        if ($result -is [string]) { Write-Host "[restore] $result" } else { Write-Host ("[restore] " + ($result | ConvertTo-Json -Compress -Depth 4)) }
    }
    if ($ReportPath) {
        $reportFile = [IO.File]::Open($ReportPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $reportBytes = [Text.Encoding]::UTF8.GetBytes(($report | ConvertTo-Json -Depth 8))
            $reportFile.Write($reportBytes, 0, $reportBytes.Length)
        } finally { $reportFile.Dispose() }
    }
}
if ($null -ne $sessionError) { throw $sessionError }
