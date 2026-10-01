# Native integration checks affect only the temporary child created below.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\ZeroStutter.Tuning.psm1') -Force
$null = Get-ZeroStutterCpuTopology

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $caught = $false
    try { $null = & $Action } catch { $caught = $true }
    if (-not $caught) { throw $Message }
}

function ConvertTo-RecoveryCopy {
    param($State)
    return ($State | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
}

function New-TestCpuSet {
    param([uint32]$Id, [byte]$EfficiencyClass, [bool]$Allocated = $false, [bool]$OwnAllocation = $false, [bool]$Parked = $false)
    $item = New-Object ZeroStutter.Native.CpuSetInfo
    $item.Id = $Id
    $item.EfficiencyClass = $EfficiencyClass
    $item.Allocated = $Allocated
    $item.AllocatedToTargetProcess = $OwnAllocation
    $item.Parked = $Parked
    return $item
}

$synthetic = [ZeroStutter.Native.CpuSetInfo[]]@(
    (New-TestCpuSet 10 0), (New-TestCpuSet 20 3), (New-TestCpuSet 30 3 $true),
    (New-TestCpuSet 40 3 $true $true), (New-TestCpuSet 50 2), (New-TestCpuSet 60 3 $false $false $true)
)
$analysis = [ZeroStutter.Native.ProcessTuner]::AnalyzeTopology($synthetic)
Assert-True ($analysis.PerformanceAvailable -and ($analysis.PerformanceCpuSetIds -join ',') -eq '20,40,60') 'Topology selection ignored efficiency classes or allocation ownership.'
$homogeneous = [ZeroStutter.Native.ProcessTuner]::AnalyzeTopology([ZeroStutter.Native.CpuSetInfo[]]@((New-TestCpuSet 1 0), (New-TestCpuSet 2 0)))
Assert-True (-not $homogeneous.PerformanceAvailable -and $homogeneous.PerformanceCpuSetIds.Length -eq 0) 'Homogeneous CPUs must not be guessed into P-core/E-core groups.'
$reserved = [ZeroStutter.Native.ProcessTuner]::AnalyzeTopology([ZeroStutter.Native.CpuSetInfo[]]@((New-TestCpuSet 1 0), (New-TestCpuSet 2 1 $true)))
Assert-True (-not $reserved.PerformanceAvailable) 'Reserved performance cores should not fall back silently to efficient cores.'
Assert-Throws { [ZeroStutter.Native.ProcessTuner]::AnalyzeTopology([ZeroStutter.Native.CpuSetInfo[]]@((New-TestCpuSet 1 0), (New-TestCpuSet 1 1))) } 'Duplicate CPU Set IDs should be rejected.'

# An independent Win32 setter simulates another app changing the child's QoS after ZeroStutter.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class ZeroStutterTuningTestProbe
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Power { public uint Version; public uint Control; public uint State; }
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetProcessInformation(IntPtr process, int kind, ref Power value, uint size);
    public static void SetPower(int processId, uint control, uint state)
    {
        using (Process process = Process.GetProcessById(processId))
        {
            Power value = new Power { Version = 1, Control = control, State = state };
            if (!SetProcessInformation(process.Handle, 4, ref value, 12)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
'@

$child = $null
$highState = $null
$cpuState = $null
$externalCpuState = $null
try {
    $shellPath = (Get-Process -Id $PID).Path
    $child = Start-Process -FilePath $shellPath -ArgumentList '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120' -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 300
    $childTopology = Get-ZeroStutterCpuTopology -ProcessId $child.Id
    $available = @($childTopology.CpuSets | Where-Object { -not $_.Allocated -or $_.AllocatedToTargetProcess })
    Assert-True ($available.Count -gt 0) 'Windows returned no CPU Sets for the temporary child.'

    $highState = New-ZeroStutterProcessTuningState -ProcessId $child.Id -HighQoS
    $journal = ConvertTo-RecoveryCopy $highState
    $before = Get-ZeroStutterProcessTuningStatus -State $highState
    Assert-True ($before.CurrentPowerControlMask -eq $highState.OriginalPowerControlMask -and $before.CurrentPowerStateMask -eq $highState.OriginalPowerStateMask) 'Preparing a session changed power throttling.'
    $null = Enable-ZeroStutterProcessTuning -State $journal
    $active = Get-ZeroStutterProcessTuningStatus -State $journal
    Assert-True ($active.ProcessAlive -and $active.SameProcess -and $active.PowerThrottlingStatus -eq 'Applied') 'HighQoS was not applied to the child.'
    Assert-True (($active.CurrentPowerControlMask -band 1) -eq 1 -and ($active.CurrentPowerStateMask -band 1) -eq 0) 'HighQoS did not explicitly disable execution-speed throttling.'
    $restored = Stop-ZeroStutterProcessTuning -State $journal
    Assert-True $restored.Succeeded ('HighQoS restoration failed: ' + ($restored.Errors -join '; '))
    $after = Get-ZeroStutterProcessTuningStatus -State $journal
    Assert-True ($after.CurrentPowerControlMask -eq $highState.OriginalPowerControlMask -and $after.CurrentPowerStateMask -eq $highState.OriginalPowerStateMask) 'HighQoS restoration did not recover both original masks.'
    Assert-True (Stop-ZeroStutterProcessTuning -State $journal).Succeeded 'Repeated restoration should be harmless.'

    # Exercise real CPU Set application even on machines without hybrid cores. The public CLI still
    # exposes only Default/Performance; this low-level call selects one known CPU Set on our child.
    $cpuState = [ZeroStutter.Native.ProcessTuner]::Prepare($child.Id, [uint32[]]@($available[0].Id), $false, 'Custom')
    $cpuJournal = ConvertTo-RecoveryCopy $cpuState
    $null = Enable-ZeroStutterProcessTuning -State $cpuState
    $cpuActive = Get-ZeroStutterProcessTuningStatus -State $cpuJournal
    Assert-True ($cpuActive.CpuSetsStatus -eq 'Applied' -and ($cpuActive.CurrentCpuSetIds -join ',') -eq [string]$available[0].Id) 'Native CPU Set assignment did not take effect.'

    # A stale PID/start-time record must never restore settings on a different process instance.
    $wrongIdentity = ConvertTo-RecoveryCopy $cpuState
    $wrongIdentity.CreationFileTime = [int64]$wrongIdentity.CreationFileTime + 1
    $mismatch = Stop-ZeroStutterProcessTuning -State $wrongIdentity
    Assert-True ($mismatch.Status -eq 'Process identity changed') 'Process creation-time mismatch was not detected.'
    Assert-True ((Get-ZeroStutterProcessTuningStatus -State $cpuState).CpuSetsStatus -eq 'Applied') 'Identity mismatch changed CPU Sets.'

    if ($available.Count -gt 1) {
        $externalCpuState = [ZeroStutter.Native.ProcessTuner]::Prepare($child.Id, [uint32[]]@($available[1].Id), $false, 'Custom')
        $null = Enable-ZeroStutterProcessTuning -State $externalCpuState
        $preserved = Stop-ZeroStutterProcessTuning -State $cpuState
        Assert-True ($preserved.CpuSetsStatus -eq 'Preserved external change') 'Restoration overwrote a later CPU Set assignment.'
        Assert-True ((Get-ZeroStutterProcessTuningStatus -State $externalCpuState).CpuSetsStatus -eq 'Applied') 'External CPU Set assignment was lost.'
        Assert-True (Stop-ZeroStutterProcessTuning -State $externalCpuState).Succeeded 'Could not unwind test CPU Set change.'
        $externalCpuState = $null
    }
    Assert-True (Stop-ZeroStutterProcessTuning -State $cpuJournal).Succeeded 'CPU Set restoration failed.'
    $cpuAfter = Get-ZeroStutterProcessTuningStatus -State $cpuState
    Assert-True (($cpuAfter.CurrentCpuSetIds -join ',') -eq ($cpuState.OriginalCpuSetIds -join ',')) 'Original CPU Sets were not restored.'

    $highState = Start-ZeroStutterProcessTuning -ProcessId $child.Id -HighQoS
    [ZeroStutterTuningTestProbe]::SetPower($child.Id, [uint32]($highState.AppliedPowerControlMask -bor 1), [uint32]($highState.AppliedPowerStateMask -bor 1))
    $preservedPower = Stop-ZeroStutterProcessTuning -State (ConvertTo-RecoveryCopy $highState)
    if ($highState.PowerThrottlingChanged) {
        Assert-True ($preservedPower.PowerThrottlingStatus -eq 'Preserved external change') 'Restoration overwrote a later EcoQoS change.'
    }
    $externalPower = Get-ZeroStutterProcessTuningStatus -State $highState
    Assert-True (($externalPower.CurrentPowerStateMask -band 1) -eq 1) 'A later power throttle setting was overwritten.'
    [ZeroStutterTuningTestProbe]::SetPower($child.Id, $highState.OriginalPowerControlMask, $highState.OriginalPowerStateMask)

    # If a snapshot becomes stale, preflight must reject it before applying even the first setting.
    $stale = [ZeroStutter.Native.ProcessTuner]::Prepare($child.Id, [uint32[]]@($available[0].Id), $true, 'Custom')
    [ZeroStutterTuningTestProbe]::SetPower($child.Id, [uint32]($stale.OriginalPowerControlMask -bor 1), [uint32]($stale.OriginalPowerStateMask -bor 1))
    Assert-Throws { Enable-ZeroStutterProcessTuning -State $stale } 'A stale power snapshot should be rejected before any CPU change.'
    $staleStatus = Get-ZeroStutterProcessTuningStatus -State $stale
    Assert-True (($staleStatus.CurrentCpuSetIds -join ',') -eq ($stale.OriginalCpuSetIds -join ',')) 'A preflight error left a partial CPU Set change.'
    [ZeroStutterTuningTestProbe]::SetPower($child.Id, $stale.OriginalPowerControlMask, $stale.OriginalPowerStateMask)

    if ($childTopology.PerformanceAvailable) {
        $performance = Start-ZeroStutterProcessTuning -ProcessId $child.Id -CpuPolicy Performance -HighQoS
        try {
            $performanceStatus = Get-ZeroStutterProcessTuningStatus -State $performance
            Assert-True (($performanceStatus.CurrentCpuSetIds -join ',') -eq ($childTopology.PerformanceCpuSetIds -join ',')) 'Performance policy selected incorrect CPU Sets.'
        } finally { Assert-True (Stop-ZeroStutterProcessTuning -State $performance).Succeeded 'Performance policy restoration failed.' }
    } else {
        Assert-Throws { Start-ZeroStutterProcessTuning -ProcessId $child.Id -CpuPolicy Performance -HighQoS } 'Performance policy should report unavailable on homogeneous CPUs.'
        $unchanged = Get-ZeroStutterProcessTuningStatus -State $stale
        Assert-True (($unchanged.CurrentCpuSetIds -join ',') -eq ($stale.OriginalCpuSetIds -join ',') -and
            $unchanged.CurrentPowerControlMask -eq $stale.OriginalPowerControlMask -and $unchanged.CurrentPowerStateMask -eq $stale.OriginalPowerStateMask) 'Unavailable Performance policy made partial changes.'
    }

    $invalid = ConvertTo-RecoveryCopy $highState
    $invalid.HighQoSRequested = 'false'
    Assert-Throws { Stop-ZeroStutterProcessTuning -State $invalid } 'String Boolean in journal must not be coerced.'
    $invalid = ConvertTo-RecoveryCopy $highState
    $invalid.ProcessId = 1.5
    Assert-Throws { Stop-ZeroStutterProcessTuning -State $invalid } 'Fractional PID in journal must be rejected.'
    $invalid = ConvertTo-RecoveryCopy $highState
    $invalid.AppliedCpuSetIds = '123'
    Assert-Throws { Stop-ZeroStutterProcessTuning -State $invalid } 'Non-array CPU Set field must be rejected.'
    $invalid = ConvertTo-RecoveryCopy $highState
    $invalid.PSObject.Properties.Remove('CreationFileTime')
    Assert-Throws { Stop-ZeroStutterProcessTuning -State $invalid } 'Missing process identity must be rejected.'
    $invalid = ConvertTo-RecoveryCopy $highState
    $invalid.SchemaVersion = 2
    Assert-Throws { Stop-ZeroStutterProcessTuning -State $invalid } 'Unknown journal schema must be rejected.'

    $child.Kill()
    $child.WaitForExit()
    Assert-True (Stop-ZeroStutterProcessTuning -State $highState).Succeeded 'Exited targets should not cause recovery failure.'
    Write-Host ('Native tuning checks passed: CPU topology selection, real CPU Set/HighQoS apply and restore, JSON recovery, external changes, stale snapshots, exited process. Hybrid policy available: {0}.' -f $childTopology.PerformanceAvailable)
} finally {
    if ($null -ne $child) {
        try {
            if (-not $child.HasExited) {
                if ($null -ne $externalCpuState) { $null = Stop-ZeroStutterProcessTuning -State $externalCpuState }
                if ($null -ne $cpuState) { $null = Stop-ZeroStutterProcessTuning -State $cpuState }
                if ($null -ne $highState) { [ZeroStutterTuningTestProbe]::SetPower($child.Id, $highState.OriginalPowerControlMask, $highState.OriginalPowerStateMask) }
            }
        } finally {
            if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit() }
            $child.Dispose()
        }
    }
}
