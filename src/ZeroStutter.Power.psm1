Set-StrictMode -Version Latest

# Powercfg operations are documented at:
# https://learn.microsoft.com/windows-hardware/design/device-experiences/powercfg-command-line-options
# CPMinCores=100 disables core parking; it does not disable CPU idle states or guarantee lower frame times.
# https://learn.microsoft.com/windows-hardware/customize/power-settings/options-for-core-parking-cpmincores
$script:PowerSession = $null
$script:GuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

function Invoke-ZeroStutterPowerCfg {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $executable = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Windows powercfg.exe is unavailable.' }
    # Capture stderr as data even in Windows PowerShell, then check the native exit code explicitly.
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $executable @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = ($output -join "`n") }
}

function Invoke-ZeroStutterRequiredPowerCfg {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $result = Invoke-ZeroStutterPowerCfg -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw "powercfg $($Arguments[0]) failed (exit $($result.ExitCode)): $($result.Output)"
    }
    return [string]$result.Output
}

function Get-ZeroStutterActivePowerScheme {
    $output = Invoke-ZeroStutterRequiredPowerCfg -Arguments @('/getactivescheme')
    # The display name may itself contain GUIDs (including our session marker).
    # Only the identifier before the parenthesized name identifies the scheme.
    $identifierPart = ($output -split '\(', 2)[0]
    $found = [regex]::Matches($identifierPart, $script:GuidPattern)
    if ($found.Count -ne 1) { throw 'Windows did not return an unambiguous active power scheme.' }
    return $found[0].Value.ToLowerInvariant()
}

function Get-ZeroStutterPowerIndex {
    param([string]$Scheme, [string]$Setting)
    if (-not ('ZeroStutter.PowerReadNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ZeroStutter {
    public static class PowerReadNative {
        [DllImport("powrprof.dll")]
        public static extern uint PowerReadACValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);
    }
}
'@ -ErrorAction Stop
    }
    $schemeGuid = [guid]$Scheme
    $subgroupGuid = [guid]'54533251-82be-4824-96c1-47b60b740d00'
    $settingGuid = [guid]$Setting
    $value = [uint32]0
    $errorCode = [ZeroStutter.PowerReadNative]::PowerReadACValueIndex([IntPtr]::Zero, [ref]$schemeGuid, [ref]$subgroupGuid, [ref]$settingGuid, [ref]$value)
    return [pscustomobject]@{ ErrorCode = $errorCode; Value = $value }
}

function Enter-ZeroStutterPowerLock {
    $mutex = $null
    try {
        # A machine-wide name prevents overlapping app sessions with different state directories.
        $mutex = New-Object System.Threading.Mutex($false, 'Global\ZeroStutter.PowerSession.v1')
        $acquired = $false
        try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another ZeroStutter power session is running. Close it before tuning or recovery.' }
        return $mutex
    } catch {
        if ($null -ne $mutex) { $mutex.Dispose() }
        throw "Could not acquire the ZeroStutter power-session lock: $($_.Exception.Message)"
    }
}

function Exit-ZeroStutterPowerLock {
    param($SessionLock)
    if ($null -ne $SessionLock) {
        try { $SessionLock.ReleaseMutex() } finally { $SessionLock.Dispose() }
    }
}

function Get-ZeroStutterPowerJournalPath {
    param([string]$StateDirectory)
    $directory = [IO.Path]::GetFullPath($StateDirectory)
    if (Test-Path -LiteralPath $directory) {
        $item = Get-Item -LiteralPath $directory -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'The power-session state directory must be a regular directory.'
        }
    }
    return Join-Path $directory 'power-session.json'
}

function Get-ZeroStutterPowerOwner {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Read-ZeroStutterPowerJournal {
    param([string]$JournalPath)
    $item = Get-Item -LiteralPath $JournalPath -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 8192) {
        throw 'The power-session journal is not a regular, bounded JSON file.'
    }
    $journal = Get-Content -LiteralPath $JournalPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    foreach ($field in @('Version', 'Application', 'Owner', 'Machine', 'SessionId', 'OriginalScheme', 'CloneScheme', 'CloneName')) {
        if ($null -eq $journal.PSObject.Properties[$field]) { throw "Invalid power-session journal: missing $field." }
    }
    if ($journal.Version -ne 1 -or $journal.Application -cne 'ZeroStutter.PowerSession' -or
        $journal.Owner -cne (Get-ZeroStutterPowerOwner) -or $journal.Machine -ine [Environment]::MachineName) {
        throw 'The power-session journal does not belong to this application, user, and computer.'
    }
    foreach ($field in @('SessionId', 'OriginalScheme', 'CloneScheme')) {
        if ($journal.$field -isnot [string] -or $journal.$field -notmatch "^$($script:GuidPattern)$" -or [guid]$journal.$field -eq [guid]::Empty) {
            throw "Invalid power-session journal GUID: $field."
        }
    }
    if ($journal.OriginalScheme -ieq $journal.CloneScheme -or $journal.CloneName -cne "ZeroStutter session $($journal.SessionId)") {
        throw 'The power-session journal has an invalid clone identity.'
    }
    return $journal
}

function Write-ZeroStutterPowerJournal {
    param([string]$JournalPath, $Journal)
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $JournalPath) -Force -ErrorAction Stop
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Journal | ConvertTo-Json -Depth 3))
    # Publish a complete, flushed file with a same-directory rename. File.Move refuses to
    # overwrite an outstanding recovery record; a crash while writing cannot truncate it.
    $temporaryPath = $JournalPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $stream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        [IO.File]::Move($temporaryPath, $JournalPath)
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -ErrorAction SilentlyContinue }
    }
}

function Complete-ZeroStutterPowerJournal {
    param([string]$JournalPath, [string]$ExpectedSessionId)
    $journal = Read-ZeroStutterPowerJournal -JournalPath $JournalPath
    if ($ExpectedSessionId -and $journal.SessionId -cne $ExpectedSessionId) { throw 'The recovery journal belongs to a different session.' }
    $listing = Invoke-ZeroStutterRequiredPowerCfg -Arguments @('/list')
    $cloneLines = @($listing -split '\r?\n' | Where-Object { $_ -match [regex]::Escape($journal.CloneScheme) })
    $active = Get-ZeroStutterActivePowerScheme
    if ($cloneLines.Count -eq 0) {
        if ($active -ieq $journal.CloneScheme) { throw 'The active session scheme was missing from the scheme list; recovery stopped.' }
        Remove-Item -LiteralPath $JournalPath -ErrorAction Stop
        return 'The temporary power scheme was already absent; cleared its recovery journal.'
    }
    if ($cloneLines.Count -ne 1 -or $cloneLines[0] -notmatch ('\(' + [regex]::Escape($journal.CloneName) + '\)\s*\*?\s*$')) {
        throw "The temporary scheme's ownership label could not be verified. Preserved scheme $($journal.CloneScheme) and its recovery journal."
    }
    $message = 'Preserved the power plan selected outside ZeroStutter.'
    if ($active -ieq $journal.CloneScheme) {
        $null = Invoke-ZeroStutterRequiredPowerCfg -Arguments @('/setactive', $journal.OriginalScheme)
        if ((Get-ZeroStutterActivePowerScheme) -ine $journal.OriginalScheme) { throw 'Windows did not restore the original power plan; retained the recovery journal.' }
        $message = 'Restored the original power plan.'
    }
    # Never delete an active plan, including one reselected during cleanup.
    if ((Get-ZeroStutterActivePowerScheme) -ieq $journal.CloneScheme) { throw 'The temporary plan became active again; retained it and its recovery journal.' }
    $null = Invoke-ZeroStutterRequiredPowerCfg -Arguments @('/delete', $journal.CloneScheme)
    Remove-Item -LiteralPath $JournalPath -ErrorAction Stop
    return "$message Removed the temporary power plan."
}

function Start-ZeroStutterPowerSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StateDirectory)
    if ($null -ne $script:PowerSession) { throw 'This process already has a ZeroStutter power session.' }
    $journalPath = Get-ZeroStutterPowerJournalPath -StateDirectory $StateDirectory
    $sessionLock = Enter-ZeroStutterPowerLock
    $journal = $null
    try {
        if (Test-Path -LiteralPath $journalPath) {
            throw 'A previous power-session journal exists. Run ZeroStutter recovery before starting another power session.'
        }
        $original = Get-ZeroStutterActivePowerScheme
        $settings = @()
        # Hidden settings may be absent from /aliases. Use the Windows SDK identifiers:
        # GUID_PROCESSOR_CORE_PARKING_MIN_CORES and GUID_PROCESSOR_CORE_PARKING_MIN_CORES_1.
        # https://github.com/microsoft/win32metadata/blob/main/generation/WinSDK/RecompiledIdlHeaders/um/winnt.h
        $knownSettings = @(
            [pscustomobject]@{ Alias = 'CPMINCORES'; Guid = '0cc5b647-c1df-4637-891a-dec35c318583' },
            [pscustomobject]@{ Alias = 'CPMINCORES1'; Guid = '0cc5b647-c1df-4637-891a-dec35c318584' }
        )
        foreach ($setting in $knownSettings) {
            $alias = $setting.Alias
            $index = Get-ZeroStutterPowerIndex -Scheme $original -Setting $setting.Guid
            if ($index.ErrorCode -ne 0) {
                if ($alias -eq 'CPMINCORES1' -and $index.ErrorCode -in @(2, 1168)) { continue }
                throw "Cannot read $alias for the active power plan (Windows error $($index.ErrorCode))."
            }
            $settings += $setting
        }
        $sessionId = [guid]::NewGuid().ToString('D')
        $journal = [pscustomobject]@{
            Version = 1; Application = 'ZeroStutter.PowerSession'; Owner = Get-ZeroStutterPowerOwner
            Machine = [Environment]::MachineName; SessionId = $sessionId; OriginalScheme = $original
            CloneScheme = [guid]::NewGuid().ToString('D'); CloneName = "ZeroStutter session $sessionId"
        }
        Write-ZeroStutterPowerJournal -JournalPath $journalPath -Journal $journal
        $null = Invoke-ZeroStutterRequiredPowerCfg -Arguments @('/duplicatescheme', $original, $journal.CloneScheme)
        $null = Invoke-ZeroStutterRequiredPowerCfg -Arguments @('/changename', $journal.CloneScheme, $journal.CloneName)
        foreach ($setting in $settings) {
            $null = Invoke-ZeroStutterRequiredPowerCfg -Arguments @('/setacvalueindex', $journal.CloneScheme, '54533251-82be-4824-96c1-47b60b740d00', $setting.Guid, '100')
            $check = Get-ZeroStutterPowerIndex -Scheme $journal.CloneScheme -Setting $setting.Guid
            if ($check.ErrorCode -ne 0 -or $check.Value -ne 100) { throw "Windows did not apply $($setting.Alias)=100 to the temporary plan." }
        }
        # Abort if the user changed power plans while the inactive clone was prepared.
        if ((Get-ZeroStutterActivePowerScheme) -ine $original) { throw 'The active power plan changed during setup. Session activation was cancelled.' }
        $null = Invoke-ZeroStutterRequiredPowerCfg -Arguments @('/setactive', $journal.CloneScheme)
        if ((Get-ZeroStutterActivePowerScheme) -ine $journal.CloneScheme) { throw 'Windows did not activate the temporary power plan.' }
        $script:PowerSession = [pscustomobject]@{
            SessionId = $journal.SessionId; OriginalScheme = $original; CloneScheme = $journal.CloneScheme
            StateDirectory = [IO.Path]::GetFullPath($StateDirectory); JournalPath = $journalPath
            SessionLock = $sessionLock; Settings = @($settings.Alias); Active = $true
        }
        return $script:PowerSession
    } catch {
        $failure = $_.Exception.Message
        if ($null -ne $journal -and (Test-Path -LiteralPath $journalPath)) {
            try { $null = Complete-ZeroStutterPowerJournal -JournalPath $journalPath -ExpectedSessionId $journal.SessionId }
            catch { $failure += " Recovery also requires attention: $($_.Exception.Message)" }
        }
        Exit-ZeroStutterPowerLock -SessionLock $sessionLock
        throw "Could not start temporary AC core-unparking: $failure"
    }
}

function Stop-ZeroStutterPowerSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    if ($null -eq $script:PowerSession -or -not [object]::ReferenceEquals($State, $script:PowerSession)) {
        throw 'Stop requires the active state object returned by Start-ZeroStutterPowerSession in this process. Use recovery after a restart.'
    }
    try { Complete-ZeroStutterPowerJournal -JournalPath $State.JournalPath -ExpectedSessionId $State.SessionId }
    finally {
        $State.Active = $false
        Exit-ZeroStutterPowerLock -SessionLock $State.SessionLock
        $State.SessionLock = $null
        $script:PowerSession = $null
    }
}

function Repair-ZeroStutterPowerSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StateDirectory)
    if ($null -ne $script:PowerSession) { throw 'Stop the current power session before running recovery.' }
    $journalPath = Get-ZeroStutterPowerJournalPath -StateDirectory $StateDirectory
    $sessionLock = Enter-ZeroStutterPowerLock
    try {
        if (-not (Test-Path -LiteralPath $journalPath)) { return 'No power-session recovery is needed.' }
        Complete-ZeroStutterPowerJournal -JournalPath $journalPath
    } finally { Exit-ZeroStutterPowerLock -SessionLock $sessionLock }
}

Export-ModuleMember -Function @('Start-ZeroStutterPowerSession', 'Stop-ZeroStutterPowerSession', 'Repair-ZeroStutterPowerSession')
