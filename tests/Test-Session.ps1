# Isolated native sessions, including recovery after the owning host is killed.
[CmdletBinding()]
param([switch]$IncludePowerPlan)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ZeroStutter-Session-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$hostProcess = Get-Process -Id $PID
$hostPath = $hostProcess.Path
$hostProcess.Dispose()
$game = $null
$session = $null
function Start-TestHost {
    param([string]$Command, [string]$Label)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
    $startedProcess = Start-Process -FilePath $hostPath -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-OutputFormat', 'Text', '-EncodedCommand', $encoded) -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $testRoot ($Label + '.out')) -RedirectStandardError (Join-Path $testRoot ($Label + '.err'))
    # Windows PowerShell's Start-Process may otherwise lose the exit-code handle.
    $null = $startedProcess.Handle
    return $startedProcess
}
function Wait-TestCondition {
    param([scriptblock]$Condition, [string]$Failure)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Condition)) {
        if ($clock.Elapsed.TotalSeconds -gt 25) { throw $Failure }
        Start-Sleep -Milliseconds 100
    }
}
try {
    $game = Start-TestHost -Command 'Start-Sleep -Seconds 180' -Label 'game'
    $game.PriorityClass = [Diagnostics.ProcessPriorityClass]::Normal
    Import-Module (Join-Path $repoRoot 'src\ZeroStutter.Tuning.psm1') -Force
    $original = New-ZeroStutterProcessTuningState -ProcessId $game.Id -HighQoS
    $scriptPath = (Join-Path $repoRoot 'ZeroStutter.ps1').Replace("'", "''")
    $state = (Join-Path $testRoot 'state').Replace("'", "''")
    $report = (Join-Path $testRoot 'report.json').Replace("'", "''")
    $command = "& '$scriptPath' -TargetProcessId $($game.Id) -Headless -Seconds 2 -StateDirectory '$state' -ReportPath '$report'"
    $session = Start-TestHost -Command $command -Label 'normal'
    if (-not $session.WaitForExit(25000)) { throw 'Timed session did not stop.' }
    if ($session.ExitCode -ne 0) { throw "Session failed (exit $($session.ExitCode)): $(Get-Content (Join-Path $testRoot 'normal.err') -Raw)" }
    $game.Refresh()
    if ($game.PriorityClass -ne [Diagnostics.ProcessPriorityClass]::Normal) { throw 'Normal exit did not restore priority.' }
    if (Test-Path -LiteralPath (Join-Path $state 'session.json')) { throw 'Normal exit retained the recovery journal.' }
    $savedReport = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if ($savedReport.PriorityStatus -notlike 'Temporary*' -or $savedReport.EndReason -ne 'Duration') { throw 'Session report did not record the applied priority and timed completion.' }
    $after = New-ZeroStutterProcessTuningState -ProcessId $game.Id -HighQoS
    if ($after.OriginalPowerControlMask -ne $original.OriginalPowerControlMask -or $after.OriginalPowerStateMask -ne $original.OriginalPowerStateMask) { throw 'Normal exit did not restore power throttling.' }
    $session.Dispose()

    $session = Start-TestHost -Command "& '$scriptPath' -TargetProcessId $($game.Id) -Headless -StateDirectory '$state'" -Label 'crash'
    Wait-TestCondition { $game.Refresh(); $game.PriorityClass -eq [Diagnostics.ProcessPriorityClass]::AboveNormal } 'The crash-test session never applied priority.'
    $competingSession = Start-TestHost -Command "& '$scriptPath' -TargetProcessId $($game.Id) -Headless -Seconds 1 -StateDirectory '$state'" -Label 'competing'
    try {
        if (-not $competingSession.WaitForExit(10000)) { $competingSession.Kill(); throw 'A concurrent session did not fail promptly.' }
        if ($competingSession.ExitCode -eq 0) { throw 'A concurrent session was allowed to tune the same game.' }
    } finally { $competingSession.Dispose() }
    $session.Kill()
    $null = $session.WaitForExit(5000)
    Wait-TestCondition { $game.Refresh(); $game.PriorityClass -eq [Diagnostics.ProcessPriorityClass]::Normal -and -not (Test-Path -LiteralPath (Join-Path $state 'session.json')) } 'Recovery helper did not restore the game after its owner was killed.'
    $afterCrash = New-ZeroStutterProcessTuningState -ProcessId $game.Id -HighQoS
    if ($afterCrash.OriginalPowerControlMask -ne $original.OriginalPowerControlMask -or $afterCrash.OriginalPowerStateMask -ne $original.OriginalPowerStateMask) { throw 'Crash recovery did not restore power throttling.' }
    $session.Dispose()
    $session = Start-TestHost -Command "& '$scriptPath' -TargetProcessId $($game.Id) -Headless -StateDirectory '$state'" -Label 'external'
    Wait-TestCondition { $game.Refresh(); $game.PriorityClass -eq [Diagnostics.ProcessPriorityClass]::AboveNormal } 'The external-change session never started.'
    $game.PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal
    $session.Kill()
    $null = $session.WaitForExit(5000)
    Wait-TestCondition { -not (Test-Path -LiteralPath (Join-Path $state 'session.json')) } 'External-change recovery never completed.'
    $game.Refresh()
    if ($game.PriorityClass -ne [Diagnostics.ProcessPriorityClass]::BelowNormal) { throw 'Crash cleanup overwrote an external priority change.' }
    $game.PriorityClass = [Diagnostics.ProcessPriorityClass]::Normal
    if ($IncludePowerPlan) {
        # Explicit opt-in only: temporarily activates an owned power-plan clone.
        $powerCfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
        $beforePlan = (& $powerCfg /getactivescheme) -join ''
        if ($LASTEXITCODE -ne 0) { throw 'Could not record the active power plan.' }
        $session.Dispose()
        $session = Start-TestHost -Command "& '$scriptPath' -TargetProcessId $($game.Id) -Headless -Seconds 2 -UnparkCores -StateDirectory '$state'" -Label 'power'
        if (-not $session.WaitForExit(25000)) { throw 'Power session did not stop.' }
        if ($session.ExitCode -ne 0) { throw "Power session failed: $(Get-Content (Join-Path $testRoot 'power.err') -Raw)" }
        $afterPlan = (& $powerCfg /getactivescheme) -join ''
        if ($LASTEXITCODE -ne 0 -or $afterPlan -ne $beforePlan) { throw 'Live power session did not restore the original active plan.' }
        if (Test-Path -LiteralPath (Join-Path $state 'power-session.json')) { throw 'Live power session left its recovery journal.' }
        Write-Host 'Live power-plan activation and restoration passed.'
    }
    Write-Host 'Session checks passed: timed cleanup, report, concurrent-session rejection, owner-crash recovery, and preserving external priority changes.'
} finally {
    if ($null -ne $session) { if (-not $session.HasExited) { $session.Kill(); $null = $session.WaitForExit(5000) }; $session.Dispose() }
    if ($null -ne $game) { if (-not $game.HasExited) { $game.Kill(); $null = $game.WaitForExit(5000) }; $game.Dispose() }
    # Keep failed-run diagnostics if recovery has not completed yet.
    if (-not (Test-Path -LiteralPath (Join-Path $testRoot 'state\session.json'))) {
        $fullRoot = [IO.Path]::GetFullPath($testRoot)
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if ($fullRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $fullRoot -Recurse -Force }
    } else { Write-Warning "Kept recovery diagnostics in $testRoot" }
}
