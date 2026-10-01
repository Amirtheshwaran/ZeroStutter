Set-StrictMode -Version Latest

# Metric definitions and CLI flags follow Intel's PresentMon console documentation:
# https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md
# https://github.com/GameTechDev/PresentMon/blob/v1.9.2/README.md#csv-columns
# Present-to-present intervals are not GPU durations or display latency.
function Get-ZeroStutterFrameReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 2147483647)][int]$ProcessId,
        [string]$SwapChainAddress,
        [ValidateSet('PresentToPresent', 'Displayed')][string]$Metric = 'PresentToPresent',
        [ValidateRange(0, 1000000)][int]$SkipFirstFrames = 0,
        [ValidateRange(0.001, 60000)][double]$SlowFrameThresholdMs = 33.333
    )
    $fullPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    $reader = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($fullPath)
    $reader.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
    $reader.SetDelimiters(',')
    $reader.HasFieldsEnclosedInQuotes = $true
    $reader.TrimWhiteSpace = $true
    $streams = @{}
    $invalidIdentityRows = 0
    try {
        if ($reader.EndOfData) { throw 'The capture CSV is empty.' }
        $headers = $reader.ReadFields()
        $columns = @{}
        for ($i = 0; $i -lt $headers.Length; $i++) {
            $name = $headers[$i].Trim()
            if ([string]::IsNullOrWhiteSpace($name) -or $columns.ContainsKey($name)) {
                throw "Empty or duplicate CSV column: '$name'."
            }
            $columns[$name] = $i
        }
        foreach ($name in @('Application', 'ProcessID', 'SwapChainAddress')) {
            if (-not $columns.ContainsKey($name)) { throw "Missing PresentMon CSV column: $name." }
        }
        if ($Metric -eq 'PresentToPresent') {
            $metricColumn = 'msBetweenPresents'
            $definition = 'Time between consecutive application Present calls, including presents that were not displayed.'
        } elseif ($columns.ContainsKey('DisplayedTime')) {
            $metricColumn = 'DisplayedTime'
            $definition = 'Duration for which each frame was displayed; unavailable or undisplayed frames are excluded.'
        } else {
            $metricColumn = 'msBetweenDisplayChange'
            $definition = 'Time between consecutive display changes; dropped or undisplayed rows are excluded.'
        }
        if (-not $columns.ContainsKey($metricColumn)) {
            throw "CSV does not contain '$metricColumn' for metric '$Metric'. Capture with --v1_metrics for PresentToPresent, or select -Metric Displayed for a compatible display capture. CPU FrameTime is not interchangeable with these metrics."
        }
        while (-not $reader.EndOfData) {
            $fields = $reader.ReadFields()
            if ($fields.Length -ne $headers.Length) { throw "CSV row near line $($reader.LineNumber) has $($fields.Length) fields; expected $($headers.Length)." }
            $rowProcessId = 0
            $rowSwapChain = $fields[$columns['SwapChainAddress']].Trim()
            if (-not [int]::TryParse($fields[$columns['ProcessID']], [ref]$rowProcessId) -or $rowProcessId -le 0 -or [string]::IsNullOrWhiteSpace($rowSwapChain)) {
                $invalidIdentityRows++
                continue
            }
            if ($PSBoundParameters.ContainsKey('ProcessId') -and $rowProcessId -ne $ProcessId) { continue }
            if (-not [string]::IsNullOrWhiteSpace($SwapChainAddress) -and $rowSwapChain -ine $SwapChainAddress) { continue }
            $key = "$rowProcessId/$rowSwapChain"
            if (-not $streams.ContainsKey($key)) {
                $streams[$key] = [pscustomobject]@{
                    ProcessId = $rowProcessId; SwapChainAddress = $rowSwapChain
                    Applications = @{}; Values = New-Object 'System.Collections.Generic.List[double]'
                    Rows = 0; Excluded = 0; Skipped = 0
                }
            }
            $stream = $streams[$key]
            $application = $fields[$columns['Application']].Trim()
            $stream.Applications[$application] = $true
            $stream.Rows++
            if ($stream.Rows -le $SkipFirstFrames) { $stream.Skipped++; continue }
            if ($metricColumn -eq 'msBetweenDisplayChange' -and $columns.ContainsKey('Dropped') -and $fields[$columns['Dropped']] -ne '0') {
                $stream.Excluded++; continue
            }
            $value = 0.0
            $valid = [double]::TryParse($fields[$columns[$metricColumn]], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)
            if (-not $valid -or [double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -le 0) {
                $stream.Excluded++; continue
            }
            $stream.Values.Add($value)
        }
    } catch {
        throw "Could not analyze '$fullPath': $($_.Exception.Message)"
    } finally { $reader.Dispose() }
    if ($streams.Count -eq 0) { throw 'No frames match the requested process and swap chain.' }
    if ($streams.Count -gt 1) {
        $available = @($streams.Values | Sort-Object ProcessId, SwapChainAddress | ForEach-Object { "PID $($_.ProcessId), swap chain $($_.SwapChainAddress) ($($_.Rows) rows)" })
        throw "Capture contains multiple frame streams. Select -ProcessId and -SwapChainAddress explicitly: $($available -join '; ')."
    }
    $selected = @($streams.Values)[0]
    if ($selected.Applications.Count -ne 1) { throw 'The selected stream changes application identity. Use a capture without process ID reuse.' }
    if ($selected.Values.Count -lt 2) { throw 'At least two valid frame intervals are required after exclusions.' }
    [double[]]$sorted = $selected.Values.ToArray()
    [Array]::Sort($sorted)
    $sum = 0.0
    $slowCount = 0
    foreach ($value in $sorted) { $sum += $value; if ($value -gt $SlowFrameThresholdMs) { $slowCount++ } }
    if ([double]::IsInfinity($sum)) { throw 'Frame interval sum overflowed. Check capture values and units.' }
    $count = $sorted.Length
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    if ($count -lt 1000) { $warnings.Add('Fewer than 1,000 valid intervals: tail percentiles are sensitive to individual frames. Use longer repeated captures.') }
    if ($selected.Excluded -gt 0) { $warnings.Add("Excluded $($selected.Excluded) unavailable, nonpositive, nonfinite, invalid or undisplayed intervals. Review exclusion counts when comparing runs.") }
    if ($invalidIdentityRows -gt 0) { $warnings.Add("Ignored $invalidIdentityRows rows with invalid process/swap-chain identity.") }
    [pscustomobject]@{
        SchemaVersion = 1; Path = $fullPath; Application = @($selected.Applications.Keys)[0]
        ProcessId = $selected.ProcessId; SwapChainAddress = $selected.SwapChainAddress
        Metric = $Metric; MetricColumn = $metricColumn; MetricDefinition = $definition; Unit = 'milliseconds'
        PercentileMethod = 'Nearest rank: sorted[ceil(percentile * count) - 1]. No interpolation.'
        FrameCount = $count; TotalRows = $selected.Rows; ExcludedRows = $selected.Excluded
        SkipFirstFrames = $SkipFirstFrames; SkippedRows = $selected.Skipped
        SumOfIntervalsSeconds = $sum / 1000.0
        MeanMs = $sum / $count
        P50Ms = $sorted[[Math]::Ceiling(0.50 * $count) - 1]
        P95Ms = $sorted[[Math]::Ceiling(0.95 * $count) - 1]
        P99Ms = $sorted[[Math]::Ceiling(0.99 * $count) - 1]
        P999Ms = $sorted[[Math]::Ceiling(0.999 * $count) - 1]
        MaximumMs = $sorted[$count - 1]
        SlowFrameThresholdMs = $SlowFrameThresholdMs; SlowFrameCount = $slowCount
        SlowFramePercent = 100.0 * $slowCount / $count
        Warnings = $warnings.ToArray()
    }
}

function Compare-ZeroStutterFrameReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Baseline, [Parameter(Mandatory)]$Candidate)
    foreach ($property in @('Metric', 'MetricColumn', 'Unit', 'PercentileMethod', 'SkipFirstFrames', 'SlowFrameThresholdMs')) {
        if ($Baseline.$property -ne $Candidate.$property) { throw "Cannot compare captures with different $property values." }
    }
    if ([string]::IsNullOrWhiteSpace($Baseline.Application) -or $Baseline.Application -eq '<unknown>' -or $Baseline.Application -ine $Candidate.Application) {
        throw 'Both captures must identify the same application executable. Unknown or different applications cannot be compared.'
    }
    $changes = [ordered]@{}
    foreach ($property in @('MeanMs', 'P50Ms', 'P95Ms', 'P99Ms', 'P999Ms', 'MaximumMs', 'SlowFramePercent')) {
        $before = [double]$Baseline.$property
        $after = [double]$Candidate.$property
        $relative = $null
        if ($before -ne 0) { $relative = 100.0 * ($after - $before) / $before }
        $changes[$property] = [pscustomobject]@{ Baseline = $before; Candidate = $after; Difference = $after - $before; ChangePercent = $relative }
    }
    [pscustomobject]@{
        SchemaVersion = 1; Baseline = $Baseline; Candidate = $Candidate; Changes = [pscustomobject]$changes
        Interpretation = 'Negative differences mean shorter intervals or fewer frames above the threshold. A single pair does not establish causation. Repeat the same scene, settings, frame cap and frame-generation mode, alternating baseline/candidate order.'
    }
}

function ConvertTo-ZeroStutterNativeArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    # Windows CommandLineToArgvW / C runtime quoting, including trailing backslashes.
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Start-ZeroStutterCaptureProcess {
    param([string]$Executable, [string[]]$Arguments)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = (@($Arguments | ForEach-Object { ConvertTo-ZeroStutterNativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Could not start PresentMon.' }
        [pscustomobject]@{ Process = $process; Output = $process.StandardOutput.ReadToEndAsync(); Error = $process.StandardError.ReadToEndAsync() }
    } catch { $process.Dispose(); throw }
}

function Invoke-ZeroStutterCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PresentMonPath,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ProcessId,
        [Parameter(Mandatory)][string]$OutputPath,
        [ValidateRange(1, 3600)][int]$Seconds = 60,
        [ValidateRange(0, 300)][int]$DelaySeconds = 5
    )
    if ($env:OS -ne 'Windows_NT') { throw 'PresentMon live capture requires Windows.' }
    $executable = (Resolve-Path -LiteralPath $PresentMonPath -ErrorAction Stop).ProviderPath
    if ([IO.Path]::GetExtension($executable) -ine '.exe' -or $executable.StartsWith('\\')) { throw 'Supply a locally installed PresentMon console .exe file.' }
    $target = Get-Process -Id $ProcessId -ErrorAction Stop
    try { $targetStart = $target.StartTime.ToUniversalTime().Ticks } finally { $target.Dispose() }
    $output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    if (Test-Path -LiteralPath $output) { throw "Capture output already exists: $output. Choose a new file to preserve previous captures." }
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $output) -PathType Container)) { throw 'The capture output directory does not exist.' }
    if ([IO.Path]::GetExtension($output) -ine '.csv') { throw 'Capture output must have a .csv extension.' }
    # Probe the supplied console CLI without requesting elevation or stopping other sessions.
    $probe = Start-ZeroStutterCaptureProcess -Executable $executable -Arguments @('--help')
    try {
        if (-not $probe.Process.WaitForExit(10000)) { throw 'PresentMon --help did not finish within 10 seconds. Supply the console executable, not the GUI application.' }
        $helpText = $probe.Output.GetAwaiter().GetResult() + $probe.Error.GetAwaiter().GetResult()
        foreach ($required in @('--process_id', '--output_file', '--timed', '--delay', '--v1_metrics', '--session_name', '--terminate_after_timed', '--terminate_on_proc_exit', '--terminate_existing_session', '--no_console_stats')) {
            if (-not $helpText.Contains($required)) { throw "The supplied executable does not advertise $required. Use the official PresentMon 2.x or newer console application." }
        }
    } finally {
        if (-not $probe.Process.HasExited) { $probe.Process.Kill(); [void]$probe.Process.WaitForExit(5000) }
        $probe.Process.Dispose()
    }
    $target = Get-Process -Id $ProcessId -ErrorAction Stop
    try { if ($target.StartTime.ToUniversalTime().Ticks -ne $targetStart) { throw 'Target process exited and its process ID was reused before capture.' } } finally { $target.Dispose() }
    $session = 'ZeroStutter-' + [Guid]::NewGuid().ToString('N')
    $arguments = @('--process_id', [string]$ProcessId, '--output_file', $output, '--timed', [string]$Seconds, '--delay', [string]$DelaySeconds, '--v1_metrics', '--session_name', $session, '--terminate_after_timed', '--terminate_on_proc_exit', '--no_console_stats')
    $capture = $null
    $completed = $false
    try {
        $capture = Start-ZeroStutterCaptureProcess -Executable $executable -Arguments $arguments
        $deadline = [DateTime]::UtcNow.AddSeconds($Seconds + $DelaySeconds + 30)
        while (-not $capture.Process.WaitForExit(200)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'PresentMon exceeded the capture timeout.' }
        }
        $details = $capture.Output.GetAwaiter().GetResult() + $capture.Error.GetAwaiter().GetResult()
        if ($capture.Process.ExitCode -ne 0) { throw "PresentMon exited with code $($capture.Process.ExitCode). $($details.Trim())" }
        if (-not (Test-Path -LiteralPath $output -PathType Leaf) -or (Get-Item -LiteralPath $output).Length -eq 0) { throw "PresentMon created no frame capture. Confirm the target is presenting frames and that your account has ETW capture access. $($details.Trim())" }
        $completed = $true
        return $output
    } finally {
        if ($null -ne $capture) {
            if (-not $completed) {
                # Stop only the unique ETW session created for this capture; never global sessions.
                $cleanup = $null
                try {
                    $cleanup = Start-ZeroStutterCaptureProcess -Executable $executable -Arguments @('--session_name', $session, '--terminate_existing_session')
                    if (-not $cleanup.Process.WaitForExit(5000)) { $cleanup.Process.Kill(); [void]$cleanup.Process.WaitForExit(5000) }
                } catch { Write-Warning "Could not stop ETW session $session automatically: $($_.Exception.Message)" }
                finally { if ($null -ne $cleanup) { $cleanup.Process.Dispose() } }
            }
            try { if (-not $capture.Process.HasExited) { $capture.Process.Kill(); [void]$capture.Process.WaitForExit(5000) } }
            finally { $capture.Process.Dispose() }
        }
    }
}

Export-ModuleMember -Function Get-ZeroStutterFrameReport, Compare-ZeroStutterFrameReport, Invoke-ZeroStutterCapture
