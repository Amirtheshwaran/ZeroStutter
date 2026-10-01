Set-StrictMode -Version Latest

function Get-ZeroStutterProfiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Profile file not found: $Path" }
    try {
        $document = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch { throw "Could not read profile file '$Path': $($_.Exception.Message)" }
    if ([string]$document.version -ne '1') { throw 'Unsupported profile version. Expected version 1.' }
    $profilesProperty = $document.PSObject.Properties['profiles']
    if ($null -eq $profilesProperty -or $profilesProperty.Value -isnot [System.Array]) { throw "Profile file must contain a 'profiles' array." }
    $profiles = @($document.profiles)
    if ($profiles.Count -eq 0) { throw 'Profile file must contain at least one profile.' }

    $seenNames = @{}
    $seenExecutables = @{}
    foreach ($profile in $profiles) {
        foreach ($required in @('name', 'executable', 'category', 'priorityClass')) {
            if ($null -eq $profile.PSObject.Properties[$required] -or
                [string]::IsNullOrWhiteSpace([string]$profile.$required)) {
                throw "Each profile must contain a non-empty '$required' value."
            }
        }
        $executable = [string]$profile.executable
        if ([IO.Path]::GetFileName($executable) -cne $executable -or $executable -notmatch '^[^\\/]+\.exe$') {
            throw "Profile '$($profile.name)' must name a .exe file, not a path."
        }
        if ([string]$profile.priorityClass -notin @('Observe', 'AboveNormal')) {
            throw "Profile '$($profile.name)' has an unsupported priorityClass. Use Observe or AboveNormal."
        }
        $nameKey = ([string]$profile.name).ToLowerInvariant()
        $executableKey = $executable.ToLowerInvariant()
        if ($seenNames.ContainsKey($nameKey)) { throw "Duplicate profile name: $($profile.name)" }
        if ($seenExecutables.ContainsKey($executableKey)) { throw "Duplicate executable profile: $executable" }
        $seenNames[$nameKey] = $true
        $seenExecutables[$executableKey] = $true
    }
    return $profiles
}

function Get-ZeroStutterTargetProcesses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Profiles,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes
    )
    $targets = @()
    foreach ($profile in $Profiles) {
        $targetName = [IO.Path]::GetFileNameWithoutExtension([string]$profile.executable)
        foreach ($process in $Processes) {
            if ([string]$process.ProcessName -ieq $targetName) {
                $priority = 'Unavailable'
                try { $priority = [string]$process.PriorityClass } catch { }
                $targets += [pscustomobject]@{
                    ProfileName       = [string]$profile.name
                    Executable        = [string]$profile.executable
                    ProcessName       = [string]$process.ProcessName
                    ProcessId         = [int]$process.Id
                    PriorityClass     = $priority
                    ConfiguredPriority = [string]$profile.priorityClass
                    Status            = if ([string]$profile.priorityClass -eq 'Observe') { 'Observe only' } else { 'Not changed' }
                    Process           = $process
                }
            }
        }
    }
    return $targets
}

function Set-ZeroStutterProfilePriorities {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Targets,
        [Parameter(Mandatory)][hashtable]$ManagedProcesses
    )
    $actions = @()
    foreach ($target in $Targets) {
        if ([string]$target.ConfiguredPriority -ne 'AboveNormal') {
            $target.Status = 'Observe only'
            continue
        }
        try {
            $process = $target.Process
            $processId = [int]$process.Id
            $startTimeTicks = $process.StartTime.ToUniversalTime().Ticks
            $identity = '{0}:{1}' -f $processId, $startTimeTicks
            if ($ManagedProcesses.ContainsKey($identity)) {
                $target.Status = 'Temporarily raised by ZeroStutter'
                continue
            }
            $currentPriority = [System.Diagnostics.ProcessPriorityClass]$process.PriorityClass
            if ($currentPriority -eq [System.Diagnostics.ProcessPriorityClass]::AboveNormal) {
                $target.Status = 'Already AboveNormal; left unchanged'
                continue
            }
            if ($currentPriority -notin @(
                [System.Diagnostics.ProcessPriorityClass]::Normal,
                [System.Diagnostics.ProcessPriorityClass]::BelowNormal
            )) {
                $target.Status = 'Skipped to preserve existing priority'
                continue
            }
            $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::AboveNormal
            $ManagedProcesses[$identity] = [pscustomobject]@{
                Process          = $process
                OriginalPriority = $currentPriority
                ProfileName      = [string]$target.ProfileName
            }
            $target.PriorityClass = 'AboveNormal'
            $target.Status = 'Temporarily raised; restore on normal exit'
            $actions += "Set $($target.ProcessName) (PID $processId) to AboveNormal."
        } catch {
            $target.Status = 'Not changed; process exited or access was denied'
        }
    }
    return $actions
}

function Remove-ZeroStutterExitedProcesses {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$ManagedProcesses)
    foreach ($identity in @($ManagedProcesses.Keys)) {
        $entry = $ManagedProcesses[$identity]
        try {
            if ($entry.Process.HasExited) {
                if ($entry.Process -is [System.Diagnostics.Process]) { $entry.Process.Dispose() }
                $null = $ManagedProcesses.Remove($identity)
            }
        } catch { $null = $ManagedProcesses.Remove($identity) }
    }
}

function Restore-ZeroStutterPriorities {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$ManagedProcesses)
    $results = @()
    foreach ($identity in @($ManagedProcesses.Keys)) {
        $entry = $ManagedProcesses[$identity]
        try {
            if ($entry.Process.HasExited) {
                $results += "$($entry.ProfileName): process ended; no restoration needed."
            } elseif ([System.Diagnostics.ProcessPriorityClass]$entry.Process.PriorityClass -eq
                [System.Diagnostics.ProcessPriorityClass]::AboveNormal) {
                $entry.Process.PriorityClass = $entry.OriginalPriority
                $results += "$($entry.ProfileName): restored its original priority."
            } else {
                $results += "$($entry.ProfileName): priority changed elsewhere; preserved that value."
            }
        } catch {
            $results += "$($entry.ProfileName): could not restore priority (process exited or access was denied)."
        } finally {
            if ($entry.Process -is [System.Diagnostics.Process]) { $entry.Process.Dispose() }
            $null = $ManagedProcesses.Remove($identity)
        }
    }
    return $results
}

Export-ModuleMember -Function @(
    'Get-ZeroStutterProfiles',
    'Get-ZeroStutterTargetProcesses',
    'Set-ZeroStutterProfilePriorities',
    'Remove-ZeroStutterExitedProcesses',
    'Restore-ZeroStutterPriorities'
)
