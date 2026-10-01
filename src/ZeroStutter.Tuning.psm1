Set-StrictMode -Version Latest

function Initialize-ZeroStutterNative {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Process tuning requires Windows 10 or Windows 11.' }
    if ($null -eq ('ZeroStutter.Native.ProcessTuner' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'ZeroStutter.Native.cs') -ErrorAction Stop
    }
}

function ConvertTo-ZeroStutterTuningState {
    param([Parameter(Mandatory)]$State)
    Initialize-ZeroStutterNative
    if ($State -is [ZeroStutter.Native.ProcessTuningState]) { return $State }
    # Reject coercions such as the string "false" becoming $true, or a fractional PID being rounded.
    $integerTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
    $limits = @{
        SchemaVersion = [decimal]1; ProcessId = [decimal][int32]::MaxValue
        CreationFileTime = [decimal]([DateTime]::MaxValue.ToFileTimeUtc())
        PowerThrottlingVersion = [decimal]1; OriginalPowerControlMask = [decimal][uint32]::MaxValue
        OriginalPowerStateMask = [decimal][uint32]::MaxValue; AppliedPowerControlMask = [decimal][uint32]::MaxValue
        AppliedPowerStateMask = [decimal][uint32]::MaxValue
    }
    foreach ($name in $limits.Keys) {
        $property = $State.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value -or $property.Value.GetType() -notin $integerTypes -or
            [decimal]$property.Value -lt 0 -or [decimal]$property.Value -gt $limits[$name]) {
            throw "Invalid integer field in process tuning snapshot: $name."
        }
    }
    foreach ($name in @('HighQoSRequested', 'CpuSetsChanged', 'PowerThrottlingChanged')) {
        $property = $State.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -isnot [bool]) { throw "Invalid Boolean field in process tuning snapshot: $name." }
    }
    foreach ($name in @('OriginalCpuSetIds', 'AppliedCpuSetIds')) {
        $property = $State.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -isnot [array] -or $property.Value.Count -gt 1048576) {
            throw "Invalid CPU Set array in process tuning snapshot: $name."
        }
        foreach ($id in $property.Value) {
            if ($null -eq $id -or $id.GetType() -notin $integerTypes -or [decimal]$id -lt 0 -or [decimal]$id -gt [decimal][uint32]::MaxValue) {
                throw "Invalid CPU Set ID in process tuning snapshot: $name."
            }
        }
    }
    if ($null -eq $State.PSObject.Properties['CpuPolicy'] -or $State.CpuPolicy -isnot [string] -or
        $State.CpuPolicy -notin @('Default', 'Performance', 'Custom')) { throw 'Invalid CPU policy in process tuning snapshot.' }
    if ($null -eq $State.PSObject.Properties['Status'] -or $State.Status -isnot [string]) { throw 'Missing status in process tuning snapshot.' }
    # Fixed fields make a ConvertFrom-Json snapshot recoverable without executing any content from it.
    $copy = New-Object ZeroStutter.Native.ProcessTuningState
    foreach ($name in @('SchemaVersion', 'ProcessId', 'CreationFileTime', 'CpuPolicy', 'HighQoSRequested',
        'OriginalCpuSetIds', 'AppliedCpuSetIds', 'CpuSetsChanged', 'PowerThrottlingVersion',
        'OriginalPowerControlMask', 'OriginalPowerStateMask', 'AppliedPowerControlMask', 'AppliedPowerStateMask',
        'PowerThrottlingChanged', 'Status')) {
        if ($null -eq $State.PSObject.Properties[$name]) { throw "Incomplete process tuning snapshot: missing $name." }
        $copy.$name = $State.$name
    }
    return $copy
}

function Get-ZeroStutterCpuTopology {
    [CmdletBinding()]
    param([ValidateRange(0, 2147483647)][int]$ProcessId = 0)
    Initialize-ZeroStutterNative
    return [ZeroStutter.Native.ProcessTuner]::GetTopology($ProcessId)
}

function New-ZeroStutterProcessTuningState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ProcessId,
        [ValidateSet('Default', 'Performance')][string]$CpuPolicy = 'Default',
        [switch]$HighQoS
    )
    Initialize-ZeroStutterNative
    $cpuSetIds = $null
    if ($CpuPolicy -eq 'Performance') {
        $topology = Get-ZeroStutterCpuTopology -ProcessId $ProcessId
        if (-not $topology.PerformanceAvailable) { throw "Performance CPU policy is unavailable: $($topology.Reason) No process settings were changed." }
        $cpuSetIds = [uint32[]]$topology.PerformanceCpuSetIds
    }
    return [ZeroStutter.Native.ProcessTuner]::Prepare($ProcessId, $cpuSetIds, $HighQoS.IsPresent, $CpuPolicy)
}

function Enable-ZeroStutterProcessTuning {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    $snapshot = ConvertTo-ZeroStutterTuningState -State $State
    return [ZeroStutter.Native.ProcessTuner]::Apply($snapshot)
}

function Start-ZeroStutterProcessTuning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ProcessId,
        [ValidateSet('Default', 'Performance')][string]$CpuPolicy = 'Default',
        [switch]$HighQoS
    )
    $state = New-ZeroStutterProcessTuningState -ProcessId $ProcessId -CpuPolicy $CpuPolicy -HighQoS:$HighQoS
    return Enable-ZeroStutterProcessTuning -State $state
}

function Stop-ZeroStutterProcessTuning {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    $snapshot = ConvertTo-ZeroStutterTuningState -State $State
    return [ZeroStutter.Native.ProcessTuner]::Restore($snapshot)
}

function Get-ZeroStutterProcessTuningStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    $snapshot = ConvertTo-ZeroStutterTuningState -State $State
    return [ZeroStutter.Native.ProcessTuner]::GetStatus($snapshot)
}

Export-ModuleMember -Function Get-ZeroStutterCpuTopology, New-ZeroStutterProcessTuningState, Enable-ZeroStutterProcessTuning, Start-ZeroStutterProcessTuning, Stop-ZeroStutterProcessTuning, Get-ZeroStutterProcessTuningStatus
