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
    Assert-Equal $dropped.PresentationDiagnostics.Rows 3 'Display diagnostics count rows before exclusions'
    Assert-Equal $dropped.PresentationDiagnostics.DroppedRows 1 'Excluded display present still counted as dropped'
    Assert-Equal $presents.PresentationDiagnostics.DroppedRows 1 'Present metric dropped count'
    Assert-Equal $display.PresentationDiagnostics.PresentModeColumnAvailable $false 'PresentMode is optional'
    Assert-Equal $display.PresentationDiagnostics.DroppedColumnAvailable $false 'Dropped is optional'
    Assert-Equal $display.PresentationDiagnostics.DroppedRows $null 'Unavailable dropped count is not zero'
    Assert-Equal $display.PresentationDiagnostics.DroppedPercentOfKnownRows $null 'Unavailable dropped percentage'

    $diagnosticHeader = $header + ',PresentMode'
    $mixedPath = Save-Fixture 'mixed-modes.csv' @($diagnosticHeader,
        'game.exe,123,0xAA,10,10,0,Hardware: Independent Flip',
        'game.exe,123,0xAA,20,20,1,Composed: Flip',
        'game.exe,123,0xAA,30,30,NA,',
        'game.exe,123,0xAA,40,40,2,unexpected mode',
        'game.exe,123,0xAA,0,0,0,NA',
        'game.exe,123,0xAA,50,50,0,Hardware: Independent Flip')
    $mixed = Get-ZeroStutterFrameReport -Path $mixedPath
    Assert-Equal $mixed.FrameCount 5 'Invalid diagnostics do not exclude valid present intervals'
    Assert-Equal $mixed.ExcludedRows 1 'Only invalid interval excluded'
    Assert-Equal $mixed.MeanMs 30 'Diagnostics preserve present interval semantics'
    Assert-Equal $mixed.PresentationDiagnostics.Rows 6 'Diagnostic row scope'
    Assert-Equal $mixed.PresentationDiagnostics.KnownPresentModeRows 3 'Known mode rows'
    Assert-Equal $mixed.PresentationDiagnostics.UnknownPresentModeRows 3 'Unknown mode rows'
    Assert-Equal $mixed.PresentationDiagnostics.MixedPresentModes $true 'Mixed mode flag'
    Assert-Equal $mixed.PresentationDiagnostics.ModeCounts.Count 2 'Mode count entries'
    Assert-Equal @($mixed.PresentationDiagnostics.ModeCounts | Where-Object Mode -eq 'Hardware: Independent Flip')[0].Rows 2 'Independent flip rows'
    Assert-Equal $mixed.PresentationDiagnostics.KnownDroppedRows 4 'Known dropped flag rows'
    Assert-Equal $mixed.PresentationDiagnostics.UnknownDroppedRows 2 'Invalid dropped flag rows'
    Assert-Equal $mixed.PresentationDiagnostics.DroppedRows 1 'Dropped rows include no unknown flags'
    Assert-Equal $mixed.PresentationDiagnostics.DroppedPercentOfKnownRows 25 'Dropped percentage denominator excludes unknown flags'
    foreach ($pattern in @('Mixed presentation modes', 'unrecognized PresentMode', 'invalid Dropped', 'not lost ETW data')) {
        if (($mixed.Warnings -join ' ') -notmatch $pattern) { throw "Missing presentation warning: $pattern" }
    }
    $mixedSkip = Get-ZeroStutterFrameReport -Path $mixedPath -SkipFirstFrames 1
    Assert-Equal $mixedSkip.PresentationDiagnostics.Rows 5 'Skipped rows excluded from diagnostics'
    Assert-Equal $mixedSkip.PresentationDiagnostics.KnownPresentModeRows 2 'Skipped known mode excluded'
    Assert-Equal $mixedSkip.PresentationDiagnostics.KnownDroppedRows 3 'Skipped known dropped flag excluded'
    $mixedDisplay = Get-ZeroStutterFrameReport -Path $mixedPath -Metric Displayed
    Assert-Equal $mixedDisplay.FrameCount 2 'Display metric retains its existing dropped/unknown flag exclusions'
    Assert-Equal $mixedDisplay.MeanMs 30 'Display metric values preserved'
    Assert-Equal $mixedDisplay.PresentationDiagnostics.DroppedRows 1 'Display diagnostics include excluded dropped rows'

    $steadyPath = Save-Fixture 'steady-mode.csv' @($diagnosticHeader,
        'game.exe,123,0xAA,10,10,0,Hardware: Independent Flip',
        'game.exe,123,0xAA,20,20,0,Hardware: Independent Flip')
    $steady = Get-ZeroStutterFrameReport -Path $steadyPath
    Assert-Equal $steady.PresentationDiagnostics.MixedPresentModes $false 'One presentation mode'
    Assert-Equal $steady.PresentationDiagnostics.ModeCounts[0].PercentOfKnownRows 100 'Single mode percentage'
    $presentationComparison = Compare-ZeroStutterFrameReport -Baseline $steady -Candidate $mixed
    foreach ($pattern in @('Candidate: Mixed presentation modes', 'distributions differ', 'contains dropped presents')) {
        if (($presentationComparison.Warnings -join ' ') -notmatch $pattern) { throw "Missing comparison warning: $pattern" }
    }
    $samePresentation = Compare-ZeroStutterFrameReport -Baseline $steady -Candidate $steady
    if (($samePresentation.Warnings -join ' ') -match 'distributions differ|contains dropped presents') { throw 'Matching undropped captures have a false presentation warning.' }
    $alternateDistributionPath = Save-Fixture 'alternate-distribution.csv' @($diagnosticHeader,
        'game.exe,123,0xAA,10,10,0,Hardware: Independent Flip',
        'game.exe,123,0xAA,20,20,0,Composed: Flip')
    $alternateDistribution = Get-ZeroStutterFrameReport -Path $alternateDistributionPath
    $changedDistribution = Compare-ZeroStutterFrameReport -Baseline $mixed -Candidate $alternateDistribution
    if (($changedDistribution.Warnings -join ' ') -notmatch 'distributions differ') { throw 'Changed mode proportions with matching mode names were not detected.' }

    $noDiagnosticsPath = Save-Fixture 'no-diagnostics.csv' @('Application,ProcessID,SwapChainAddress,msBetweenPresents',
        'game.exe,123,0xAA,10', 'game.exe,123,0xAA,20')
    $noDiagnostics = Get-ZeroStutterFrameReport -Path $noDiagnosticsPath
    $missingDiagnostics = Compare-ZeroStutterFrameReport -Baseline $steady -Candidate $noDiagnostics
    foreach ($pattern in @('Presentation-mode diagnostics are unavailable', 'Dropped-frame diagnostics are unavailable')) {
        if (($missingDiagnostics.Warnings -join ' ') -notmatch $pattern) { throw "Missing availability warning: $pattern" }
    }
    $oldReport = $steady.PSObject.Copy()
    $oldReport.PSObject.Properties.Remove('PresentationDiagnostics')
    $oldComparison = Compare-ZeroStutterFrameReport -Baseline $oldReport -Candidate $oldReport
    Assert-Equal $oldComparison.Changes.MeanMs.Difference 0 'Reports without additive diagnostics still compare'
    $mixedVersionComparison = Compare-ZeroStutterFrameReport -Baseline $oldReport -Candidate $steady
    if (($mixedVersionComparison.Warnings -join ' ') -notmatch 'Presentation diagnostics are unavailable') { throw 'Old report availability warning missing.' }
    $allUnknownPath = Save-Fixture 'unknown-diagnostics.csv' @($diagnosticHeader,
        'game.exe,123,0xAA,10,10,NA,Unknown', 'game.exe,123,0xAA,20,20,invalid,')
    $allUnknown = Get-ZeroStutterFrameReport -Path $allUnknownPath
    Assert-Equal $allUnknown.FrameCount 2 'All optional diagnostics may be unknown'
    Assert-Equal $allUnknown.PresentationDiagnostics.ModeCounts.Count 0 'Unknown mode produces no invented category'
    Assert-Equal $allUnknown.PresentationDiagnostics.UnknownPresentModeRows 2 'All mode rows unknown'
    Assert-Equal $allUnknown.PresentationDiagnostics.UnknownDroppedRows 2 'All dropped flags unknown'
    Assert-Equal $allUnknown.PresentationDiagnostics.DroppedPercentOfKnownRows $null 'No division by zero for unknown flags'

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
    $diagnosticJsonPath = Join-Path $testDirectory 'presentation-comparison.json'
    $cliWarnings = @()
    & (Join-Path $repoRoot 'Measure-ZeroStutter.ps1') -BaselinePath $steadyPath -CandidatePath $mixedPath -JsonPath $diagnosticJsonPath -WarningVariable cliWarnings -WarningAction SilentlyContinue
    $diagnosticJson = Get-Content -LiteralPath $diagnosticJsonPath -Raw | ConvertFrom-Json
    Assert-Equal $diagnosticJson.Candidate.PresentationDiagnostics.UnknownPresentModeRows 3 'JSON optional diagnostics preserved'
    if (($diagnosticJson.Warnings -join ' ') -notmatch 'distributions differ' -or ($cliWarnings -join ' ') -notmatch 'distributions differ') { throw 'Comparison diagnostic warning missing from CLI or JSON.' }
    Assert-Equal @($cliWarnings | Where-Object { $_ -match 'Candidate: Mixed presentation modes' }).Count 1 'CLI prints aggregate warning only once'
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
        string header = "Application,ProcessID,SwapChainAddress,msBetweenPresents\n";
        string row = "game.exe," + Value(args, "--process_id") + ",0x01,";
        if (output.EndsWith("header-only.csv")) { File.WriteAllText(output, header); return 0; }
        if (output.EndsWith("invalid-intervals.csv")) { File.WriteAllText(output, header + row + "0\n" + row + "NA\n" + row + "NaN\n" + row + "Infinity\n" + row + "-1\n"); return 0; }
        if (output.EndsWith("wrong-pid.csv")) { File.WriteAllText(output, header + "game.exe,0,0x01,10\ngame.exe,0,0x01,20\n"); return 0; }
        if (output.EndsWith("single-frame.csv")) { File.WriteAllText(output, header + row + "10\n"); return 0; }
        File.WriteAllText(output, header + row + "10\n" + row + "20\n");
        if (output.EndsWith("multiple-streams.csv")) File.AppendAllText(output, "game.exe," + Value(args, "--process_id") + ",0x02,30\n");
        Console.WriteLine("fixture capture complete");
        if (output.EndsWith("warnings.csv")) Console.Error.WriteLine("warning: fixture diagnostic needs attention.\n         continuation context.");
        if (output.EndsWith("lost-events.csv")) Console.Error.WriteLine("warning: 2 ETW events were lost.");
        if (output.EndsWith("lost-buffers.csv")) Console.Error.WriteLine("warning: 1 ETW buffers were lost.");
        if (output.EndsWith("overflow.csv")) Console.Error.WriteLine("warning: 3 overflowed present events detected. This could be due to a high-fps application.");
        if (output.EndsWith("lost-status.csv")) Console.WriteLine("[ETW Status] EventsLost=0 BuffersLost=2, OverflowedPresents=0");
        if (output.EndsWith("overflow-status.csv")) Console.WriteLine("[ETW Status] EventsLost=0 BuffersLost=0, OverflowedPresents=10");
        if (output.EndsWith("zero-status.csv")) Console.WriteLine("[ETW Status] EventsLost=0 BuffersLost=0, OverflowedPresents=0");
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
        $diagnostics = Get-Content -LiteralPath ($capturePath + '.presentmon.log') -Raw
        if ($diagnostics -notmatch 'fixture capture complete' -or $diagnostics -notmatch 'Exit code: 0') { throw 'Successful capture diagnostics were not preserved.' }
        Assert-Throws { Invoke-ZeroStutterCapture -PresentMonPath $executablePath -ProcessId $PID -OutputPath $capturePath -Seconds 1 -DelaySeconds 0 } 'already exists'
        $failurePath = Join-Path $testDirectory 'failure.csv'
        Assert-Throws { Invoke-ZeroStutterCapture -PresentMonPath $executablePath -ProcessId $PID -OutputPath $failurePath -Seconds 1 -DelaySeconds 0 } 'fixture capture failure'
        $invocations = @(Get-Content -LiteralPath $env:ZEROSTUTTER_CAPTURE_TEST_LOG)
        Assert-Equal $invocations.Count 3 'One successful capture, one failure and one cleanup'
        Assert-Equal $invocations[2].Substring(8) $invocations[1].Substring(8) 'Cleanup targets its own session'
        if ($invocations[0] -eq $invocations[1]) { throw 'Capture session names must be unique.' }
        if ((Get-Content -LiteralPath ($failurePath + '.presentmon.log') -Raw) -notmatch 'fixture capture failure') { throw 'Failed capture diagnostics were not preserved.' }

        $existingLogPath = Join-Path $testDirectory 'existing-log.csv'
        [IO.File]::WriteAllText(($existingLogPath + '.presentmon.log'), 'preserve this log')
        Assert-Throws { Invoke-ZeroStutterCapture -PresentMonPath $executablePath -ProcessId $PID -OutputPath $existingLogPath -Seconds 1 -DelaySeconds 0 } 'diagnostics already exist'
        Assert-Equal (Get-Content -LiteralPath ($existingLogPath + '.presentmon.log') -Raw) 'preserve this log' 'Existing diagnostic log preserved'
        Assert-Equal @(Get-Content -LiteralPath $env:ZEROSTUTTER_CAPTURE_TEST_LOG).Count 3 'Existing log rejected before starting capture'
        Assert-Equal (Test-Path -LiteralPath $existingLogPath) $false 'Existing log prevents capture output creation'

        $warningPath = Join-Path $testDirectory 'warnings.csv'
        $captureWarnings = @()
        $warningSaved = Invoke-ZeroStutterCapture -PresentMonPath $executablePath -ProcessId $PID -OutputPath $warningPath -Seconds 1 -DelaySeconds 0 -WarningVariable captureWarnings -WarningAction SilentlyContinue
        Assert-Equal $warningSaved $warningPath 'Non-loss warning does not reject valid capture'
        if (($captureWarnings -join ' ') -notmatch 'fixture diagnostic needs attention') { throw 'PresentMon warnings were not surfaced.' }
        if ((Get-Content -LiteralPath ($warningPath + '.presentmon.log') -Raw) -notmatch 'continuation context') { throw 'Multiline warning context was not preserved.' }

        foreach ($name in @('lost-events', 'lost-buffers', 'overflow', 'lost-status', 'overflow-status')) {
            $rejectedPath = Join-Path $testDirectory ($name + '.csv')
            Assert-Throws { Invoke-ZeroStutterCapture -PresentMonPath $executablePath -ProcessId $PID -OutputPath $rejectedPath -Seconds 1 -DelaySeconds 0 -WarningAction SilentlyContinue } 'lost ETW data or overflowed presents'
            Assert-Equal (Test-Path -LiteralPath $rejectedPath -PathType Leaf) $true 'Rejected data retained for inspection'
            Assert-Equal (Test-Path -LiteralPath ($rejectedPath + '.presentmon.log') -PathType Leaf) $true 'Rejected diagnostics retained for inspection'
        }
        foreach ($name in @('header-only', 'invalid-intervals', 'wrong-pid', 'single-frame')) {
            $rejectedPath = Join-Path $testDirectory ($name + '.csv')
            Assert-Throws { Invoke-ZeroStutterCapture -PresentMonPath $executablePath -ProcessId $PID -OutputPath $rejectedPath -Seconds 1 -DelaySeconds 0 } 'No usable frame stream'
            Assert-Equal (Test-Path -LiteralPath $rejectedPath -PathType Leaf) $true 'Empty/invalid capture retained for inspection'
        }
        foreach ($name in @('zero-status', 'multiple-streams')) {
            $acceptedPath = Join-Path $testDirectory ($name + '.csv')
            $accepted = Invoke-ZeroStutterCapture -PresentMonPath $executablePath -ProcessId $PID -OutputPath $acceptedPath -Seconds 1 -DelaySeconds 0
            Assert-Equal $accepted $acceptedPath 'Valid capture accepted'
        }
        Assert-Throws { Get-ZeroStutterFrameReport -Path (Join-Path $testDirectory 'multiple-streams.csv') } 'multiple frame streams'
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
