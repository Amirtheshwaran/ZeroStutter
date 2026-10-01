#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$StateDirectory = (Join-Path $env:LOCALAPPDATA 'ZeroStutter\State'),
    [switch]$WatchOwner,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$SessionId
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\ZeroStutter.Recovery.psm1') -Force
$journalPath = Join-Path $StateDirectory 'session.json'
if ($WatchOwner) {
    if (-not $SessionId) { throw 'A watched session requires its unique SessionId.' }
    $journal = Read-ZeroStutterSessionJournal -Path $journalPath
    if ($journal.SessionId -ne $SessionId) { throw 'The recovery helper was given a different session identity.' }
    $readyPath = Join-Path $StateDirectory ($SessionId + '.ready')
    Set-Content -LiteralPath $readyPath -Value 'ready' -Encoding ASCII
    while (Test-Path -LiteralPath $journalPath -PathType Leaf) {
        if (-not (Test-Path -LiteralPath $journalPath)) { return }
        try { $journal = Read-ZeroStutterSessionJournal -Path $journalPath }
        catch { if (-not (Test-Path -LiteralPath $journalPath)) { return }; throw }
        if ($journal.SessionId -ne $SessionId) { return }
        if (-not (Test-ZeroStutterOwnerAlive -Journal $journal)) { break }
        Start-Sleep -Seconds 1
    }
    if (-not (Test-Path -LiteralPath $journalPath)) { return }
}
$lock = New-Object System.Threading.Mutex($false, 'Local\ZeroStutter.GameSession.v1')
$held = $false
try {
    try { $held = $lock.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another game session is running. End it before recovery.' }
    Repair-ZeroStutterSession -StateDirectory $StateDirectory
} finally {
    if ($held) { $lock.ReleaseMutex() }
    $lock.Dispose()
}
