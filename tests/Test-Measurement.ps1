# Deterministic frame statistics checks; no game, ETW session, or tuning is started.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
foreach ($relative in @('Measure-ZeroStutter.ps1', 'src\ZeroStutter.Measurement.psm1')) {
    $tokens = $null; $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $relative), [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) { throw "Parse error in ${relative}: $($parseErrors.Message -join '; ')" }
}
Import-Module (Join-Path $repoRoot 'src\ZeroStutter.Measurement.psm1') -Force
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "${Message}: expected '$Expected', got '$Actual'." }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $caught = $false
    try { & $Action | Out-Null } catch {
        $caught = $true
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected exception: $($_.Exception.Message). Expected pattern: $Pattern" }
    }
    if (-not $caught) { throw "Expected an exception matching '$Pattern'." }
}
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('ZeroStutter-Measurement-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
function Save-Fixture([string]$Name, [string[]]$Rows) {
    $fixturePath = Join-Path $testDirectory $Name
    [IO.File]::WriteAllLines($fixturePath, $Rows, [Text.Encoding]::UTF8)
    $fixturePath
}
try {
    $header = 'Application,ProcessID,SwapChainAddress,msBetweenPresents,msBetweenDisplayChange,Dropped'
    $baselinePath = Save-Fixture 'baseline.csv' (@($header) + @(1..100 | ForEach-Object { "game.exe,123,0xAA,$_,$_,0" }))
    $baseline = Get-ZeroStutterFrameReport -Path $baselinePath -SlowFrameThresholdMs 50
    Assert-Equal $baseline.FrameCount 100 'Sample count'
    Assert-Equal $baseline.MeanMs 50.5 'Arithmetic mean'
    Assert-Equal $baseline.P50Ms 50 'Nearest rank median'
    Assert-Equal $baseline.P95Ms 95 'P95'
    Assert-Equal $baseline.P99Ms 99 'P99'
    Assert-Equal $baseline.P999Ms 100 'P99.9'
    Assert-Equal $baseline.SlowFrameCount 50 'Strict greater-than threshold'
    Assert-Equal $baseline.SlowFramePercent 50 'Threshold percentage'
    $skip = Get-ZeroStutterFrameReport -Path $baselinePath -SkipFirstFrames 98
    Assert-Equal $skip.FrameCount 2 'Skip rows'
    Assert-Equal $skip.MeanMs 99.5 'Skip mean'
    Assert-Throws { Get-ZeroStutterFrameReport -Path $baselinePath -SkipFirstFrames 99 } 'At least two'

    $candidatePath = Save-Fixture 'candidate.csv' @($header, 'GAME.exe,456,0xBB,10,10,0', 'GAME.exe,456,0xBB,10,10,0')
    $candidate = Get-ZeroStutterFrameReport -Path $candidatePath -SlowFrameThresholdMs 50
    $comparison = Compare-ZeroStutterFrameReport -Baseline $baseline -Candidate $candidate
    Assert-Equal $comparison.Changes.P99Ms.Difference -89 'Comparison difference'
    Assert-Equal $comparison.Changes.SlowFramePercent.ChangePercent -100 'Comparison percent'
    $zeroComparison = Compare-ZeroStutterFrameReport -Baseline $candidate -Candidate $candidate
    Assert-Equal $zeroComparison.Changes.SlowFramePercent.ChangePercent $null 'No divide by zero'

    $invalidPath = Save-Fixture 'invalid.csv' @($header, 'game.exe,123,0xAA,0,0,0', 'game.exe,123,0xAA,-1,0,0', 'game.exe,123,0xAA,NA,NA,0', 'game.exe,123,0xAA,NaN,NA,0', 'game.exe,123,0xAA,Infinity,NA,0', 'game.exe,123,0xAA,garbage,0,0', 'game.exe,123,0xAA,10.5,10.5,0', 'game.exe,123,0xAA,20.5,20.5,0')
    $invalid = Get-ZeroStutterFrameReport -Path $invalidPath
    Assert-Equal $invalid.ExcludedRows 6 'Excluded invalid values'
    Assert-Equal $invalid.MeanMs 15.5 'Invariant numeric parser'
    $previousCulture = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
        $german = Get-ZeroStutterFrameReport -Path $invalidPath
        Assert-Equal $german.MeanMs 15.5 'Locale independent parsing'
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture }

    $multiplePath = Save-Fixture 'multiple.csv' @($header, 'game.exe,123,0xAA,10,10,0', 'game.exe,123,0xAA,20,20,0', 'game.exe,123,0xBB,900,900,0', 'other.exe,456,0xCC,1000,1000,0')
    Assert-Throws { Get-ZeroStutterFrameReport -Path $multiplePath } 'multiple frame streams'
    Assert-Throws { Get-ZeroStutterFrameReport -Path $multiplePath -ProcessId 123 } 'multiple frame streams'
    $filtered = Get-ZeroStutterFrameReport -Path $multiplePath -ProcessId 123 -SwapChainAddress '0xaa'
    Assert-Equal $filtered.MeanMs 15 'Explicit stream selection'
    Assert-Throws { Get-ZeroStutterFrameReport -Path $multiplePath -ProcessId 999 } 'No frames match'

    $displayPath = Save-Fixture 'display.csv' @('Application,ProcessID,SwapChainAddress,DisplayedTime,FrameTime', 'game.exe,123,0xAA,10,1', 'game.exe,123,0xAA,20,2', 'game.exe,123,0xAA,NA,3')
    $display = Get-ZeroStutterFrameReport -Path $displayPath -Metric Displayed
    Assert-Equal $display.MeanMs 15 'DisplayedTime statistics'
    Assert-Equal $display.ExcludedRows 1 'Unavailable displayed frame'
    Assert-Throws { Get-ZeroStutterFrameReport -Path $displayPath } 'does not contain'
    $displayV1 = Get-ZeroStutterFrameReport -Path $baselinePath -Metric Displayed
    Assert-Throws { Compare-ZeroStutterFrameReport -Baseline $displayV1 -Candidate $display } 'different MetricColumn'
    Assert-Throws { Compare-ZeroStutterFrameReport -Baseline $baseline -Candidate $display } 'different Metric'
    $droppedPath = Save-Fixture 'dropped.csv' @($header, 'game.exe,123,0xAA,10,10,0', 'game.exe,123,0xAA,20,20,0', 'game.exe,123,0xAA,30,500,1')
    $dropped = Get-ZeroStutterFrameReport -Path $droppedPath -Metric Displayed
    Assert-Equal $dropped.MeanMs 15 'Dropped intervals excluded from display metric'
    $presents = Get-ZeroStutterFrameReport -Path $droppedPath
    Assert-Equal $presents.MeanMs 20 'Dropped presents retained for present metric'

    $empty = Save-Fixture 'empty.csv' @()
    Assert-Throws { Get-ZeroStutterFrameReport -Path $empty } 'empty'
    $malformed = Save-Fixture 'malformed.csv' @($header, 'game.exe,123,0xAA,1,1,0,unexpected')
    Assert-Throws { Get-ZeroStutterFrameReport -Path $malformed } 'fields'
    $badQuote = Save-Fixture 'bad-quote.csv' @($header, '"unterminated,123,0xAA,1,1,0')
    Assert-Throws { Get-ZeroStutterFrameReport -Path $badQuote } 'Could not analyze'
    $duplicate = Save-Fixture 'duplicate.csv' @('Application,ProcessID,SwapChainAddress,msBetweenPresents,msbetweenpresents', 'game.exe,123,0xAA,1,2')
    Assert-Throws { Get-ZeroStutterFrameReport -Path $duplicate } 'duplicate'
    $missing = Save-Fixture 'missing.csv' @('Application,msBetweenPresents', 'game.exe,1', 'game.exe,2')
    Assert-Throws { Get-ZeroStutterFrameReport -Path $missing } 'Missing PresentMon'
    $quoted = Save-Fixture 'quoted.csv' @($header, '"game, test.exe",123,0xAA,1,1,0', '"game, test.exe",123,0xAA,3,3,0')
    $quotedReport = Get-ZeroStutterFrameReport -Path $quoted
    Assert-Equal $quotedReport.Application 'game, test.exe' 'Quoted application field'
    Assert-Equal $quotedReport.MeanMs 2 'Quoted CSV parsing'
    Assert-Throws { Compare-ZeroStutterFrameReport -Baseline $baseline -Candidate $quotedReport } 'different SlowFrameThresholdMs'
    $differentApplication = Get-ZeroStutterFrameReport -Path $quoted -SlowFrameThresholdMs 50
    Assert-Throws { Compare-ZeroStutterFrameReport -Baseline $baseline -Candidate $differentApplication } 'same application'

    $jsonPath = Join-Path $testDirectory 'comparison.json'
    & (Join-Path $repoRoot 'Measure-ZeroStutter.ps1') -BaselinePath $baselinePath -CandidatePath $candidatePath -JsonPath $jsonPath
    $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    Assert-Equal $json.Baseline.FrameCount 100 'JSON baseline count'
    Assert-Equal $json.Changes.P99Ms.Difference -89 'JSON exact difference'
    Assert-Throws { & (Join-Path $repoRoot 'Measure-ZeroStutter.ps1') -CsvPath $baselinePath -JsonPath $jsonPath } 'already exists'
    & (Join-Path $repoRoot 'Measure-ZeroStutter.ps1') -CsvPath $displayPath -Metric Displayed

    # Compile our own harmless console fixture to exercise process creation, quoting,
    # help negotiation and cleanup. This does not invoke PresentMon or start ETW.
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler)) { throw "The capture integration fixture requires the Windows .NET Framework C# compiler: $compiler" }
    $fixtureSource = @'
using System;
using System.IO;
class CaptureFixture {
    static string Value(string[] args, string key) {
        int index = Array.IndexOf(args, key);
        return index < 0 || index + 1 >= args.Length ? "" : args[index + 1];
    }
    static int Main(string[] args) {
        if (Array.IndexOf(args, "--help") >= 0) {
            Console.WriteLine("--process_id --output_file --timed --delay --v1_metrics --session_name --terminate_after_timed --terminate_on_proc_exit --terminate_existing_session --no_console_stats");
            return 0;
        }
        string session = Value(args, "--session_name");
        string log = Environment.GetEnvironmentVariable("ZEROSTUTTER_CAPTURE_TEST_LOG");
        if (Array.IndexOf(args, "--terminate_existing_session") >= 0) {
            File.AppendAllText(log, "cleanup:" + session + "\n");
            return 0;
        }
        File.AppendAllText(log, "capture:" + session + "\n");
        if (!session.StartsWith("ZeroStutter-")) return 8;
        if (Value(args, "--timed") != "1" || Value(args, "--delay") != "0") return 9;
        if (Array.IndexOf(args, "--v1_metrics") < 0 || Array.IndexOf(args, "--terminate_after_timed") < 0 || Array.IndexOf(args, "--terminate_on_proc_exit") < 0) return 10;
        string output = Value(args, "--output_file");
        if (output.EndsWith("failure.csv")) { Console.Error.WriteLine("fixture capture failure"); return 4; }
        File.WriteAllText(output, "Application,ProcessID,SwapChainAddress,msBetweenPresents\ngame.exe," + Value(args, "--process_id") + ",0x01,10\ngame.exe," + Value(args, "--process_id") + ",0x01,20\n");
        return 0;
    }
}
'@
    $sourcePath = Save-Fixture 'CaptureFixture.cs' @($fixtureSource)
    $executablePath = Join-Path $testDirectory 'Capture Fixture.exe'
    & $compiler /nologo /target:exe "/out:$executablePath" $sourcePath
    if ($LASTEXITCODE -ne 0) { throw 'Capture fixture compilation failed.' }
    $previousLog = $env:ZEROSTUTTER_CAPTURE_TEST_LOG
    $env:ZEROSTUTTER_CAPTURE_TEST_LOG = Join-Path $testDirectory 'capture.log'
    try {
        $capturePath = Join-Path $testDirectory 'capture with spaces.csv'
        $saved = Invoke-ZeroStutterCapture -PresentMonPath $executablePath -ProcessId $PID -OutputPath $capturePath -Seconds 1 -DelaySeconds 0
        Assert-Equal $saved $capturePath 'Capture output path with spaces'
        $captured = Get-ZeroStutterFrameReport -Path $saved
        Assert-Equal $captured.ProcessId $PID 'Capture PID argument'
        Assert-Equal $captured.MeanMs 15 'Capture fixture values'
        Assert-Throws { Invoke-ZeroStutterCapture -PresentMonPath $executablePath -ProcessId $PID -OutputPath $capturePath -Seconds 1 -DelaySeconds 0 } 'already exists'
        $failurePath = Join-Path $testDirectory 'failure.csv'
        Assert-Throws { Invoke-ZeroStutterCapture -PresentMonPath $executablePath -ProcessId $PID -OutputPath $failurePath -Seconds 1 -DelaySeconds 0 } 'fixture capture failure'
        $invocations = @(Get-Content -LiteralPath $env:ZEROSTUTTER_CAPTURE_TEST_LOG)
        Assert-Equal $invocations.Count 3 'One successful capture, one failure and one cleanup'
        Assert-Equal $invocations[2].Substring(8) $invocations[1].Substring(8) 'Cleanup targets its own session'
        if ($invocations[0] -eq $invocations[1]) { throw 'Capture session names must be unique.' }
    } finally { $env:ZEROSTUTTER_CAPTURE_TEST_LOG = $previousLog }
    Write-Host 'All measurement checks passed.'
} finally {
    # Delete only fixture files in our own verified, unique temporary directory.
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $actualParent = [IO.Path]::GetFullPath((Split-Path -Parent $testDirectory)).TrimEnd('\')
    if ($actualParent -ine $expectedParent -or (Split-Path -Leaf $testDirectory) -notmatch '^ZeroStutter-Measurement-[a-f0-9]{32}$') { throw 'Refusing unexpected test cleanup path.' }
    Get-ChildItem -LiteralPath $testDirectory -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    Remove-Item -LiteralPath $testDirectory -Force
}
