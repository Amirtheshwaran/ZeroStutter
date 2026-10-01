Set-StrictMode -Version Latest

function Read-ZeroStutterSessionJournal {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 1MB) {
        throw 'The session journal must be a regular JSON file smaller than 1 MB.'
    }
    $journal = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($journal.Version -ne 1 -or $journal.Application -cne 'ZeroStutter.GameSession' -or
        $journal.Owner -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or
        $journal.Machine -ine [Environment]::MachineName -or $journal.SessionId -notmatch '^[a-f0-9]{32}$' -or
        [int]$journal.OwnerProcessId -le 0 -or [long]$journal.OwnerCreationFileTime -le 0) {
        throw 'The recovery journal is invalid or belongs to a different user/computer.'
    }
    return $journal
}

function Write-ZeroStutterSessionJournal {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Journal)
    $temporaryPath = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $stream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Journal | ConvertTo-Json -Depth 8))
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
    try { [IO.File]::Move($temporaryPath, $Path) }
    finally { if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force } }
}

function Test-ZeroStutterOwnerAlive {
    param([Parameter(Mandatory)]$Journal)
    $ownerProcess = $null
    try {
        $ownerProcess = Get-Process -Id ([int]$Journal.OwnerProcessId) -ErrorAction Stop
        return ($ownerProcess.StartTime.ToUniversalTime().ToFileTimeUtc() -eq [long]$Journal.OwnerCreationFileTime)
    } catch [Microsoft.PowerShell.Commands.ProcessCommandException] { return $false }
    finally { if ($null -ne $ownerProcess) { $ownerProcess.Dispose() } }
}

function Repair-ZeroStutterSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateDirectory, [switch]$AllowCurrentOwner)
    $journalPath = Join-Path $StateDirectory 'session.json'
    if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
        $journal = Read-ZeroStutterSessionJournal -Path $journalPath
        $currentOwner = [int]$journal.OwnerProcessId -eq $PID
        if ((Test-ZeroStutterOwnerAlive $journal) -and -not ($AllowCurrentOwner -and $currentOwner)) {
            throw 'The owner of this tuning session is still running. End that session before recovery.'
        }
        $errors = @()
        Import-Module (Join-Path $PSScriptRoot 'ZeroStutter.Tuning.psm1') -Force
        try {
            $nativeResult = Stop-ZeroStutterProcessTuning -State $journal.Tuning
            Write-Output $nativeResult
            if (-not $nativeResult.Succeeded) { $errors += $nativeResult.Errors }
        } catch { $errors += $_.Exception.Message }
        $process = $null
        try {
            $process = Get-Process -Id ([int]$journal.Tuning.ProcessId) -ErrorAction Stop
            if ($process.StartTime.ToUniversalTime().ToFileTimeUtc() -eq [long]$journal.Tuning.CreationFileTime) {
                if ($journal.Priority.Changed -and [string]$process.PriorityClass -eq [string]$journal.Priority.Applied) {
                    if ([string]$journal.Priority.Original -notin @('Normal', 'BelowNormal') -or [string]$journal.Priority.Applied -ne 'AboveNormal') { throw 'Invalid priority recovery record.' }
                    $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]([string]$journal.Priority.Original)
                    Write-Output 'Restored the original process priority.'
                } else { Write-Output 'Priority already restored or changed elsewhere; preserved.' }
            } else { Write-Output 'Original target exited; replacement PID preserved.' }
        } catch [Microsoft.PowerShell.Commands.ProcessCommandException] { Write-Output 'Target exited; priority recovery unnecessary.' }
        catch { $errors += $_.Exception.Message }
        finally { if ($null -ne $process) { $process.Dispose() } }
        if ($journal.UnparkCores) {
            try {
                Import-Module (Join-Path $PSScriptRoot 'ZeroStutter.Power.psm1') -Force
                Repair-ZeroStutterPowerSession -StateDirectory $StateDirectory
            } catch { $errors += $_.Exception.Message }
        }
        if ($errors.Count -gt 0) { throw "Recovery incomplete; journal retained. $($errors -join '; ')" }
        Remove-Item -LiteralPath $journalPath -Force -ErrorAction Stop
    } else {
        Import-Module (Join-Path $PSScriptRoot 'ZeroStutter.Power.psm1') -Force
        Repair-ZeroStutterPowerSession -StateDirectory $StateDirectory
    }
}

Export-ModuleMember -Function Repair-ZeroStutterSession, Test-ZeroStutterOwnerAlive, Read-ZeroStutterSessionJournal, Write-ZeroStutterSessionJournal
