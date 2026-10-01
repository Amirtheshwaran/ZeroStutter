#Requires -Version 5.1
<#
.SYNOPSIS
Capture and compare application frame pacing using Intel PresentMon CSV files.
.DESCRIPTION
Present-to-present intervals measure application submission pacing; Displayed measures
screen-visible frame durations. These measurements cannot identify a stutter's cause.
All intervals and percentiles use milliseconds. Percentiles use nearest rank (no
interpolation). SkipFirstFrames removes that many CSV rows from the selected stream
before validity checks. There is no automatic outlier trimming. Compare repeatable
scenes with identical settings, frame cap, frame generation and capture options.
Obtain the console application from https://github.com/GameTechDev/PresentMon/releases.
ZeroStutter does not download or bundle PresentMon. Capture executes only the local
executable explicitly supplied with PresentMonPath. Its --help must advertise the
required version 2+ options. ETW capture may require Performance Log Users membership
or an elevated shell; this command does not change group membership or self-elevate.
.EXAMPLE
.\Measure-ZeroStutter.ps1 -Capture -PresentMonPath C:\Tools\PresentMon.exe -ProcessId 1234 -OutputPath .\baseline.csv
.EXAMPLE
.\Measure-ZeroStutter.ps1 -BaselinePath .\baseline.csv -CandidatePath .\candidate.csv -JsonPath .\comparison.json
.EXAMPLE
.\Measure-ZeroStutter.ps1 -CsvPath .\capture.csv -Metric Displayed -ProcessId 1234 -SwapChainAddress 0x123
#>
[CmdletBinding(DefaultParameterSetName = 'Analyze')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Capture')][switch]$Capture,
    [Parameter(Mandatory, ParameterSetName = 'Capture')][string]$PresentMonPath,
    [Parameter(Mandatory, ParameterSetName = 'Capture')][string]$OutputPath,
    [Parameter(ParameterSetName = 'Capture')][ValidateRange(1, 3600)][int]$Seconds = 60,
    [Parameter(ParameterSetName = 'Capture')][ValidateRange(0, 300)][int]$DelaySeconds = 5,
    [Parameter(Mandatory, ParameterSetName = 'Analyze')][string]$CsvPath,
    [Parameter(Mandatory, ParameterSetName = 'Capture')][Parameter(ParameterSetName = 'Analyze')][ValidateRange(1, 2147483647)][int]$ProcessId,
    [Parameter(ParameterSetName = 'Analyze')][string]$SwapChainAddress,
    [Parameter(Mandatory, ParameterSetName = 'Compare')][string]$BaselinePath,
    [Parameter(Mandatory, ParameterSetName = 'Compare')][string]$CandidatePath,
    [Parameter(ParameterSetName = 'Compare')][ValidateRange(1, 2147483647)][int]$BaselineProcessId,
    [Parameter(ParameterSetName = 'Compare')][ValidateRange(1, 2147483647)][int]$CandidateProcessId,
    [Parameter(ParameterSetName = 'Compare')][string]$BaselineSwapChain,
    [Parameter(ParameterSetName = 'Compare')][string]$CandidateSwapChain,
    [Parameter(ParameterSetName = 'Analyze')][Parameter(ParameterSetName = 'Compare')][ValidateSet('PresentToPresent', 'Displayed')][string]$Metric = 'PresentToPresent',
    [Parameter(ParameterSetName = 'Analyze')][Parameter(ParameterSetName = 'Compare')][ValidateRange(0, 1000000)][int]$SkipFirstFrames = 0,
    [Parameter(ParameterSetName = 'Analyze')][Parameter(ParameterSetName = 'Compare')][ValidateRange(0.001, 60000)][double]$SlowFrameThresholdMs = 33.333,
    [Parameter(ParameterSetName = 'Analyze')][Parameter(ParameterSetName = 'Compare')][string]$JsonPath
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\ZeroStutter.Measurement.psm1') -Force
if ($PSCmdlet.ParameterSetName -eq 'Capture') {
    Write-Host "Capturing PID $ProcessId for $Seconds seconds after a $DelaySeconds second delay."
    $saved = Invoke-ZeroStutterCapture -PresentMonPath $PresentMonPath -ProcessId $ProcessId -OutputPath $OutputPath -Seconds $Seconds -DelaySeconds $DelaySeconds
    Write-Host "Capture saved: $saved"
    Write-Host 'Analyze it with -CsvPath, or compare runs with -BaselinePath and -CandidatePath.'
    return
}
if ($JsonPath -and (Test-Path -LiteralPath $JsonPath)) { throw "Report already exists: $JsonPath. Choose a new JSON output file." }
$common = @{ Metric = $Metric; SkipFirstFrames = $SkipFirstFrames; SlowFrameThresholdMs = $SlowFrameThresholdMs }
if ($PSCmdlet.ParameterSetName -eq 'Compare') {
    $beforeArgs = @{ Path = $BaselinePath }
    $afterArgs = @{ Path = $CandidatePath }
    if ($PSBoundParameters.ContainsKey('BaselineProcessId')) { $beforeArgs.ProcessId = $BaselineProcessId }
    if ($PSBoundParameters.ContainsKey('CandidateProcessId')) { $afterArgs.ProcessId = $CandidateProcessId }
    if ($BaselineSwapChain) { $beforeArgs.SwapChainAddress = $BaselineSwapChain }
    if ($CandidateSwapChain) { $afterArgs.SwapChainAddress = $CandidateSwapChain }
    $before = Get-ZeroStutterFrameReport @beforeArgs @common
    $after = Get-ZeroStutterFrameReport @afterArgs @common
    $report = Compare-ZeroStutterFrameReport -Baseline $before -Candidate $after
    Write-Host "Frame pacing comparison: $($before.Application) | $($before.MetricColumn) | milliseconds"
    Write-Host "Intervals: baseline $($before.FrameCount), candidate $($after.FrameCount). Excluded: $($before.ExcludedRows) / $($after.ExcludedRows)."
    $rows = foreach ($property in $report.Changes.PSObject.Properties) {
        $change = $property.Value
        $percent = 'n/a'
        if ($null -ne $change.ChangePercent) { $percent = '{0:+0.00;-0.00;0.00}%' -f $change.ChangePercent }
        [pscustomobject]@{ Metric = $property.Name; Baseline = [Math]::Round($change.Baseline, 3); Candidate = [Math]::Round($change.Candidate, 3); Change = $percent }
    }
    $rows | Format-Table -AutoSize | Out-Host
    Write-Host "SlowFramePercent counts intervals above $SlowFrameThresholdMs ms."
    Write-Host $report.Interpretation
    foreach ($warning in @($before.Warnings) + @($after.Warnings)) { Write-Warning $warning }
} else {
    $arguments = @{ Path = $CsvPath }
    if ($PSBoundParameters.ContainsKey('ProcessId')) { $arguments.ProcessId = $ProcessId }
    if ($SwapChainAddress) { $arguments.SwapChainAddress = $SwapChainAddress }
    $report = Get-ZeroStutterFrameReport @arguments @common
    $report | Select-Object Application, ProcessId, SwapChainAddress, MetricColumn, FrameCount, ExcludedRows, SkippedRows, MeanMs, P50Ms, P95Ms, P99Ms, P999Ms, MaximumMs, SlowFrameThresholdMs, SlowFrameCount, SlowFramePercent | Format-List | Out-Host
    Write-Host $report.MetricDefinition
    Write-Host $report.PercentileMethod
    foreach ($warning in $report.Warnings) { Write-Warning $warning }
}
if ($JsonPath) {
    $jsonOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($JsonPath)
    $file = [IO.File]::Open($jsonOutput, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($report | ConvertTo-Json -Depth 8))
        $file.Write($bytes, 0, $bytes.Length)
    } finally { $file.Dispose() }
    Write-Host "JSON report saved: $jsonOutput"
}
