# No system power settings are changed: every powercfg command and native power read is mocked.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\ZeroStutter.Power.psm1'
Import-Module $modulePath -Force
$powerModule = Get-Module ZeroStutter.Power
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('ZeroStutter-Power-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testDirectory

function Assert-Power($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-PowerThrows([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert-Power $failed $Message
}

& $powerModule {
    function script:Reset-PowerMock {
        $script:Fake = @{
            Original = '381b4222-f694-41f0-9685-ff5bb260df2e'
            Active = '381b4222-f694-41f0-9685-ff5bb260df2e'
            Other = 'a1841308-3541-4fab-bc81-f71556f20b4a'
            Schemes = @{}; Calls = (New-Object 'System.Collections.Generic.List[string]')
            FailCommand = ''; FailCount = 0; FailAfterMutation = $false; Hybrid = $true
            WrongReadBack = $false; Locks = 0; Concurrent = $false
        }
        $script:Fake.Schemes[$script:Fake.Original] = @{ Name = 'User customized plan'; Min = 37; Min1 = 24; DC = 12 }
        $script:Fake.Schemes[$script:Fake.Other] = @{ Name = 'Another plan'; Min = 5; Min1 = 5; DC = 5 }
    }
    function script:Get-ZeroStutterPowerOwner { return 'S-1-5-21-TestOwner' }
    function script:Enter-ZeroStutterPowerLock {
        if ($script:Fake.Concurrent) { throw 'Another session holds the lock.' }
        $script:Fake.Locks++
        return [pscustomobject]@{ Fake = $true }
    }
    function script:Exit-ZeroStutterPowerLock { param($SessionLock) $script:Fake.Locks-- }
    function script:Get-ZeroStutterPowerIndex {
        param([string]$Scheme, [string]$Setting)
        $entry = $script:Fake.Schemes[$Scheme]
        if ($Setting -eq '0cc5b647-c1df-4637-891a-dec35c318584') {
            if (-not $script:Fake.Hybrid) { return [pscustomobject]@{ ErrorCode = 2; Value = 0 } }
            return [pscustomobject]@{ ErrorCode = 0; Value = $entry.Min1 }
        }
        if ($script:Fake.WrongReadBack -and $Scheme -ne $script:Fake.Original) { return [pscustomobject]@{ ErrorCode = 0; Value = 0 } }
        return [pscustomobject]@{ ErrorCode = 0; Value = $entry.Min }
    }
    function script:Invoke-ZeroStutterPowerCfg {
        param([string[]]$Arguments)
        $script:Fake.Calls.Add(($Arguments -join '|'))
        $command = $Arguments[0]
        $fail = $command -eq $script:Fake.FailCommand -and $script:Fake.FailCount -gt 0
        if ($fail) { $script:Fake.FailCount-- }
        if ($fail -and -not $script:Fake.FailAfterMutation) { return [pscustomobject]@{ ExitCode = 5; Output = 'Mock access denied.' } }
        $output = ''
        switch ($command) {
            # Include the actual name: session names contain another GUID.
            '/getactivescheme' { $output = "Localized label: $($script:Fake.Active) ($($script:Fake.Schemes[$script:Fake.Active].Name))" }
            '/list' {
                $output = ($script:Fake.Schemes.Keys | ForEach-Object {
                    "Localized label: $_ ($($script:Fake.Schemes[$_].Name)) $(if ($_ -eq $script:Fake.Active) { '*' })"
                }) -join "`n"
            }
            '/duplicatescheme' {
                if ($script:Fake.Schemes.ContainsKey($Arguments[2])) { throw 'Mock duplicate GUID collision.' }
                $script:Fake.Schemes[$Arguments[2]] = $script:Fake.Schemes[$Arguments[1]].Clone()
            }
            '/changename' { $script:Fake.Schemes[$Arguments[1]].Name = $Arguments[2] }
            '/setacvalueindex' {
                if ($Arguments[1] -eq $script:Fake.Original) { throw 'Attempt to mutate original plan.' }
                if ($Arguments[3] -eq '0cc5b647-c1df-4637-891a-dec35c318583') { $script:Fake.Schemes[$Arguments[1]].Min = [int]$Arguments[4] }
                elseif ($Arguments[3] -eq '0cc5b647-c1df-4637-891a-dec35c318584') { $script:Fake.Schemes[$Arguments[1]].Min1 = [int]$Arguments[4] }
                else { throw 'Unexpected setting.' }
            }
            '/setactive' { $script:Fake.Active = $Arguments[1] }
            '/delete' {
                if ($Arguments[1] -eq $script:Fake.Active -or $Arguments[1] -eq $script:Fake.Original) { throw 'Attempt to delete an active or original plan.' }
                $script:Fake.Schemes.Remove($Arguments[1])
            }
            default { throw "Unexpected power command: $command" }
        }
        if ($fail) { return [pscustomobject]@{ ExitCode = 5; Output = 'Mock failure after applying.' } }
        return [pscustomobject]@{ ExitCode = 0; Output = $output }
    }
    Reset-PowerMock
}

try {
    $state = Start-ZeroStutterPowerSession -StateDirectory $testDirectory
    $initial = & $powerModule {
        $clone = $script:Fake.Schemes[$script:PowerSession.CloneScheme]
        $original = $script:Fake.Schemes[$script:Fake.Original]
        return ($clone.Min -eq 100 -and $clone.Min1 -eq 100 -and $clone.DC -eq 12 -and
            $original.Min -eq 37 -and $original.Min1 -eq 24 -and $original.DC -eq 12 -and $script:Fake.Locks -eq 1)
    }
    Assert-Power $initial 'Session did not preserve original/DC settings and apply both AC settings.'
    Assert-Power (Test-Path -LiteralPath $state.JournalPath) 'Session did not persist its recovery journal.'
    Assert-PowerThrows { Start-ZeroStutterPowerSession -StateDirectory $testDirectory } 'A second session in one process was allowed.'
    $null = Stop-ZeroStutterPowerSession -State $state
    Assert-Power (& $powerModule { $script:Fake.Active -eq $script:Fake.Original -and $script:Fake.Schemes.Count -eq 2 -and $script:Fake.Locks -eq 0 }) 'Normal shutdown did not restore and clean up.'
    Assert-Power (-not (Test-Path -LiteralPath $state.JournalPath)) 'Normal shutdown retained its journal.'

    # An external power plan selection is preserved, and the owned inactive clone is removed.
    & $powerModule { Reset-PowerMock }
    $state = Start-ZeroStutterPowerSession -StateDirectory $testDirectory
    & $powerModule { $script:Fake.Active = $script:Fake.Other }
    $null = Stop-ZeroStutterPowerSession -State $state
    Assert-Power (& $powerModule { $script:Fake.Active -eq $script:Fake.Other -and $script:Fake.Schemes.Count -eq 2 }) 'Shutdown overwrote an external plan selection.'

    # Optional hybrid policy is not required when the native read says it is absent.
    & $powerModule { Reset-PowerMock; $script:Fake.Hybrid = $false }
    $state = Start-ZeroStutterPowerSession -StateDirectory $testDirectory
    Assert-Power ($state.Settings.Count -eq 1) 'Absent hybrid policy was not skipped.'
    $null = Stop-ZeroStutterPowerSession -State $state

    foreach ($failedCommand in @('/duplicatescheme', '/setacvalueindex', '/setactive')) {
        & $powerModule { param($Command) Reset-PowerMock; $script:Fake.FailCommand = $Command; $script:Fake.FailCount = 1 } $failedCommand
        Assert-PowerThrows { Start-ZeroStutterPowerSession -StateDirectory $testDirectory } "Native failure $failedCommand was ignored."
        Assert-Power (& $powerModule { $script:Fake.Active -eq $script:Fake.Original -and $script:Fake.Schemes.Count -eq 2 -and $script:Fake.Locks -eq 0 }) "Failure $failedCommand left a changed active plan, clone, or held lock."
        Assert-Power (-not (Test-Path -LiteralPath (Join-Path $testDirectory 'power-session.json'))) "Failure $failedCommand retained a cleanable journal."
    }
    & $powerModule { Reset-PowerMock; $script:Fake.FailCommand = '/setactive'; $script:Fake.FailCount = 1; $script:Fake.FailAfterMutation = $true }
    Assert-PowerThrows { Start-ZeroStutterPowerSession -StateDirectory $testDirectory } 'A reported activation failure after mutation was ignored.'
    Assert-Power (& $powerModule { $script:Fake.Active -eq $script:Fake.Original -and $script:Fake.Schemes.Count -eq 2 }) 'Activation failure after mutation was not rolled back.'

    & $powerModule { Reset-PowerMock; $script:Fake.WrongReadBack = $true }
    Assert-PowerThrows { Start-ZeroStutterPowerSession -StateDirectory $testDirectory } 'Incorrect native setting read-back was ignored.'
    Assert-Power (& $powerModule { $script:Fake.Active -eq $script:Fake.Original -and $script:Fake.Schemes.Count -eq 2 }) 'Failed setting verification did not roll back.'

    # A stopped process loses its mutex but retains the disk journal and power plan.
    & $powerModule { Reset-PowerMock }
    $state = Start-ZeroStutterPowerSession -StateDirectory $testDirectory
    & $powerModule { $script:PowerSession = $null; $script:Fake.Locks = 0 }
    $null = Repair-ZeroStutterPowerSession -StateDirectory $testDirectory
    Assert-Power (& $powerModule { $script:Fake.Active -eq $script:Fake.Original -and $script:Fake.Schemes.Count -eq 2 -and $script:Fake.Locks -eq 0 }) 'Crash recovery did not restore the original plan.'

    # A delete failure preserves the journal so the next recovery can finish.
    & $powerModule { Reset-PowerMock }
    $state = Start-ZeroStutterPowerSession -StateDirectory $testDirectory
    & $powerModule { $script:Fake.FailCommand = '/delete'; $script:Fake.FailCount = 1 }
    Assert-PowerThrows { Stop-ZeroStutterPowerSession -State $state } 'Delete failure was ignored.'
    Assert-Power (Test-Path -LiteralPath $state.JournalPath) 'Delete failure lost recovery information.'
    $null = Repair-ZeroStutterPowerSession -StateDirectory $testDirectory
    Assert-Power (-not (Test-Path -LiteralPath $state.JournalPath)) 'Retry did not finish cleanup.'

    # Restore failure keeps the still-active owned clone and journal for an explicit retry.
    & $powerModule { Reset-PowerMock }
    $state = Start-ZeroStutterPowerSession -StateDirectory $testDirectory
    & $powerModule { $script:Fake.FailCommand = '/setactive'; $script:Fake.FailCount = 1 }
    Assert-PowerThrows { Stop-ZeroStutterPowerSession -State $state } 'Restore failure was ignored.'
    Assert-Power (& $powerModule { $script:Fake.Schemes.Count -eq 3 -and $script:Fake.Active -ne $script:Fake.Original -and $script:Fake.Locks -eq 0 }) 'Restore failure deleted its active clone or retained the process lock.'
    Assert-Power (Test-Path -LiteralPath $state.JournalPath) 'Restore failure lost recovery information.'
    $null = Repair-ZeroStutterPowerSession -StateDirectory $testDirectory

    # A crash/failure between duplication and ownership naming must not delete an unverified plan.
    & $powerModule { Reset-PowerMock; $script:Fake.FailCommand = '/changename'; $script:Fake.FailCount = 1 }
    Assert-PowerThrows { Start-ZeroStutterPowerSession -StateDirectory $testDirectory } 'Naming failure was ignored.'
    $journalPath = Join-Path $testDirectory 'power-session.json'
    Assert-Power (Test-Path -LiteralPath $journalPath) 'An unnamed clone lost its recovery journal.'
    Assert-Power (& $powerModule { $script:Fake.Schemes.Count -eq 3 -and $script:Fake.Active -eq $script:Fake.Original }) 'An unnamed clone was activated or removed without verification.'
    $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
    & $powerModule { param($Journal) $script:Fake.Schemes[$Journal.CloneScheme].Name = $Journal.CloneName } $journal
    $null = Repair-ZeroStutterPowerSession -StateDirectory $testDirectory

    # A renamed clone is never deleted on the strength of a GUID in a journal alone.
    & $powerModule { Reset-PowerMock }
    $state = Start-ZeroStutterPowerSession -StateDirectory $testDirectory
    & $powerModule { $script:Fake.Schemes[$script:PowerSession.CloneScheme].Name = 'User renamed this plan' }
    Assert-PowerThrows { Stop-ZeroStutterPowerSession -State $state } 'An unverified plan was deleted.'
    Assert-Power (Test-Path -LiteralPath $state.JournalPath) 'An unverified clone lost its recovery journal.'
    & $powerModule { param($Clone, $Session) $script:Fake.Schemes[$Clone].Name = "ZeroStutter session $Session" } $state.CloneScheme $state.SessionId
    $null = Repair-ZeroStutterPowerSession -StateDirectory $testDirectory

    # Tampering cannot turn recovery into deletion of the original or another arbitrary plan.
    & $powerModule { Reset-PowerMock }
    $state = Start-ZeroStutterPowerSession -StateDirectory $testDirectory
    & $powerModule { $script:PowerSession = $null; $script:Fake.Locks = 0 }
    $savedJournal = Get-Content -LiteralPath $state.JournalPath -Raw
    $journal = $savedJournal | ConvertFrom-Json
    $journal.CloneScheme = $journal.OriginalScheme
    $journal | ConvertTo-Json | Set-Content -LiteralPath $state.JournalPath -Encoding UTF8
    Assert-PowerThrows { Repair-ZeroStutterPowerSession -StateDirectory $testDirectory } 'An original-equals-clone journal was accepted.'
    $savedJournal | Set-Content -LiteralPath $state.JournalPath -Encoding UTF8
    $null = Repair-ZeroStutterPowerSession -StateDirectory $testDirectory

    & $powerModule { Reset-PowerMock }
    $state = Start-ZeroStutterPowerSession -StateDirectory $testDirectory
    & $powerModule { $script:PowerSession = $null; $script:Fake.Locks = 0 }
    $savedJournal = Get-Content -LiteralPath $state.JournalPath -Raw
    $journal = $savedJournal | ConvertFrom-Json
    $journal.Owner = 'DifferentUser'
    $journal | ConvertTo-Json | Set-Content -LiteralPath $state.JournalPath -Encoding UTF8
    Assert-PowerThrows { Repair-ZeroStutterPowerSession -StateDirectory $testDirectory } 'A journal owned by another user was accepted.'
    $savedJournal | Set-Content -LiteralPath $state.JournalPath -Encoding UTF8
    $null = Repair-ZeroStutterPowerSession -StateDirectory $testDirectory

    & $powerModule { Reset-PowerMock; $script:Fake.Concurrent = $true }
    Assert-PowerThrows { Start-ZeroStutterPowerSession -StateDirectory $testDirectory } 'A concurrently held session lock was ignored.'
    Assert-Power (& $powerModule { $script:Fake.Calls.Count -eq 0 }) 'Power operations ran without a session lock.'
    Write-Output 'Power session checks passed (mocked native calls; no system power settings changed).'
} finally {
    Remove-Module ZeroStutter.Power -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($testDirectory)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -like 'ZeroStutter-Power-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
