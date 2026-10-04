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
    # Unrecognized/new modes remain unknown diagnostics; they never invalidate intervals.
    # Names follow the PresentMon console documentation, including legacy CSV output.
    $knownPresentModes = @{}
    foreach ($mode in @('Hardware: Legacy Flip', 'Hardware: Legacy Copy to front buffer',
        'Hardware: Independent Flip', 'Composed: Flip', 'Hardware Composed: Independent Flip',
        'Composed: Copy with GPU GDI', 'Composed: Copy with CPU GDI')) { $knownPresentModes[$mode] = $mode }
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
                    ModeCounts = @{}; KnownModeRows = 0; UnknownModeRows = 0
                    DroppedRows = 0; KnownDroppedRows = 0; UnknownDroppedRows = 0
                }
            }
            $stream = $streams[$key]
            $application = $fields[$columns['Application']].Trim()
            $stream.Applications[$application] = $true
            $stream.Rows++
            if ($stream.Rows -le $SkipFirstFrames) { $stream.Skipped++; continue }
            # Count diagnostics before metric exclusions so undisplayed presents remain visible
            # even when the selected metric intentionally excludes their intervals.
            if ($columns.ContainsKey('PresentMode')) {
                $mode = $fields[$columns['PresentMode']].Trim()
                if ($knownPresentModes.ContainsKey($mode)) {
                    $mode = $knownPresentModes[$mode]
                    if (-not $stream.ModeCounts.ContainsKey($mode)) { $stream.ModeCounts[$mode] = 0 }
                    $stream.ModeCounts[$mode]++
                    $stream.KnownModeRows++
                } else { $stream.UnknownModeRows++ }
            }
            if ($columns.ContainsKey('Dropped')) {
                $dropped = $fields[$columns['Dropped']].Trim()
                if ($dropped -eq '0' -or $dropped -eq '1') {
                    $stream.KnownDroppedRows++
                    if ($dropped -eq '1') { $stream.DroppedRows++ }
                } else { $stream.UnknownDroppedRows++ }
            }
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
    $modeCounts = @($selected.ModeCounts.Keys | Sort-Object | ForEach-Object {
        [pscustomobject]@{ Mode = $_; Rows = $selected.ModeCounts[$_]; PercentOfKnownRows = 100.0 * $selected.ModeCounts[$_] / $selected.KnownModeRows }
    })
    $droppedPercent = $null
    if ($selected.KnownDroppedRows -gt 0) { $droppedPercent = 100.0 * $selected.DroppedRows / $selected.KnownDroppedRows }
    $presentation = [pscustomobject]@{
        Scope = 'Selected stream rows after SkipFirstFrames, before metric validity and undisplayed-frame exclusions.'
        Rows = $selected.Rows - $selected.Skipped
        PresentModeColumnAvailable = $columns.ContainsKey('PresentMode')
        KnownPresentModeRows = $selected.KnownModeRows
        UnknownPresentModeRows = $(if ($columns.ContainsKey('PresentMode')) { $selected.UnknownModeRows } else { $null })
        ModeCounts = $modeCounts
        MixedPresentModes = ($modeCounts.Count -gt 1)
        DroppedColumnAvailable = $columns.ContainsKey('Dropped')
        KnownDroppedRows = $selected.KnownDroppedRows
        UnknownDroppedRows = $(if ($columns.ContainsKey('Dropped')) { $selected.UnknownDroppedRows } else { $null })
        DroppedRows = $(if ($columns.ContainsKey('Dropped')) { $selected.DroppedRows } else { $null })
        DroppedPercentOfKnownRows = $droppedPercent
    }
    if ($presentation.MixedPresentModes) {
        $warnings.Add('Mixed presentation modes were recorded. Focus, window/display conditions or composition may have changed; the trace does not establish the cause. Review the capture before attributing timing changes to tuning.')
    }
    if ($selected.UnknownModeRows -gt 0) { $warnings.Add("$($selected.UnknownModeRows) rows have unavailable or unrecognized PresentMode values. They remain unknown in presentation diagnostics; otherwise valid intervals are retained.") }
    if ($selected.UnknownDroppedRows -gt 0) { $warnings.Add("$($selected.UnknownDroppedRows) rows have unavailable or invalid Dropped flags. Dropped percentages use only known 0/1 flags. Interval validity still follows the selected metric.") }
    if ($selected.DroppedRows -gt 0) {
        $percentText = $droppedPercent.ToString('F2', [Globalization.CultureInfo]::InvariantCulture)
        $warnings.Add("PresentMon marked $($selected.DroppedRows) of $($selected.KnownDroppedRows) known rows as Dropped ($percentText%). These presents were not displayed; Dropped is not lost ETW data. PresentToPresent retains their intervals, so submission pacing can differ from visible smoothness.")
    }
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
        PresentationDiagnostics = $presentation
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
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in @(@('Baseline', $Baseline), @('Candidate', $Candidate))) {
        if ($entry[1].PSObject.Properties['Warnings']) {
            foreach ($warning in @($entry[1].Warnings)) { $warnings.Add("$($entry[0]): $warning") }
        }
    }
    $beforePresentation = $null; $afterPresentation = $null
    if ($Baseline.PSObject.Properties['PresentationDiagnostics']) { $beforePresentation = $Baseline.PresentationDiagnostics }
    if ($Candidate.PSObject.Properties['PresentationDiagnostics']) { $afterPresentation = $Candidate.PresentationDiagnostics }
    if ($null -ne $beforePresentation -and $null -ne $afterPresentation) {
        if ($beforePresentation.KnownPresentModeRows -gt 0 -and $afterPresentation.KnownPresentModeRows -gt 0) {
            $beforeModes = @{}; $afterModes = @{}
            foreach ($mode in @($beforePresentation.ModeCounts)) { $beforeModes[$mode.Mode] = $mode.PercentOfKnownRows }
            foreach ($mode in @($afterPresentation.ModeCounts)) { $afterModes[$mode.Mode] = $mode.PercentOfKnownRows }
            $differentModes = $false
            foreach ($mode in @(@($beforeModes.Keys) + @($afterModes.Keys) | Sort-Object -Unique)) {
                if (-not $beforeModes.ContainsKey($mode) -or -not $afterModes.ContainsKey($mode) -or
                    [Math]::Abs([double]$beforeModes[$mode] - [double]$afterModes[$mode]) -gt 0.000001) { $differentModes = $true }
            }
            if ($differentModes) { $warnings.Add('Presentation-mode distributions differ between captures. Verify the same focus, window/display conditions and scene before attributing timing differences to tuning; no intervals were automatically removed.') }
        } elseif ($beforePresentation.KnownPresentModeRows -gt 0 -or $afterPresentation.KnownPresentModeRows -gt 0) {
            $warnings.Add('Presentation-mode diagnostics are unavailable in one capture, so matching presentation conditions cannot be checked.')
        }
        if ($beforePresentation.DroppedRows -gt 0 -or $afterPresentation.DroppedRows -gt 0) {
            $warnings.Add('At least one capture contains dropped presents. Compare the dropped counts and presentation conditions before interpreting performance differences. These flags do not indicate lost ETW events, and they do not establish the cause of a timing change.')
        }
        if (($beforePresentation.KnownDroppedRows -gt 0) -ne ($afterPresentation.KnownDroppedRows -gt 0)) {
            $warnings.Add('Dropped-frame diagnostics are unavailable in one capture; an unavailable count must not be interpreted as zero dropped presents.')
        }
    } elseif ($null -ne $beforePresentation -or $null -ne $afterPresentation) {
        $warnings.Add('Presentation diagnostics are unavailable in one report. Re-analyze both captures to inspect presentation conditions and dropped-frame counts.')
    }
    [pscustomobject]@{
        SchemaVersion = 1; Baseline = $Baseline; Candidate = $Candidate; Changes = [pscustomobject]$changes
        Warnings = $warnings.ToArray()
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

function Assert-ZeroStutterCaptureData {
    param([string]$Path, [int]$ProcessId)
    # Capture can contain several swap chains. Require usable intervals in at
    # least one stream, leaving stream selection to the analysis command.
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    $reader = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($Path)
    $reader.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
    $reader.SetDelimiters(',')
    $reader.HasFieldsEnclosedInQuotes = $true
    $reader.TrimWhiteSpace = $true
    $validByStream = @{}
    try {
        if ($reader.EndOfData) { throw 'The capture CSV is empty.' }
        $headers = $reader.ReadFields()
        $columns = @{}
        for ($i = 0; $i -lt $headers.Length; $i++) {
            $name = $headers[$i].Trim()
            if ([string]::IsNullOrWhiteSpace($name) -or $columns.ContainsKey($name)) { throw "Empty or duplicate CSV column: '$name'." }
            $columns[$name] = $i
        }
        foreach ($name in @('Application', 'ProcessID', 'SwapChainAddress', 'msBetweenPresents')) {
            if (-not $columns.ContainsKey($name)) { throw "Missing PresentMon CSV column: $name." }
        }
        while (-not $reader.EndOfData) {
            $fields = $reader.ReadFields()
            if ($fields.Length -ne $headers.Length) { throw "CSV row near line $($reader.LineNumber) has $($fields.Length) fields; expected $($headers.Length)." }
            $rowProcessId = 0
            $value = 0.0
            $swapChain = $fields[$columns['SwapChainAddress']]
            if (-not [int]::TryParse($fields[$columns['ProcessID']], [ref]$rowProcessId) -or $rowProcessId -ne $ProcessId -or [string]::IsNullOrWhiteSpace($swapChain)) { continue }
            if (-not [double]::TryParse($fields[$columns['msBetweenPresents']], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -or [double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -le 0) { continue }
            if (-not $validByStream.ContainsKey($swapChain)) { $validByStream[$swapChain] = 0 }
            # Only the existence of two intervals matters; avoid accumulating
            # frame data or allowing counter overflow in long captures.
            if ($validByStream[$swapChain] -lt 2) { $validByStream[$swapChain]++ }
        }
        if (@($validByStream.Values | Where-Object { $_ -ge 2 }).Count -eq 0) {
            throw "No usable frame stream for PID ${ProcessId}: at least two valid positive Present intervals are required. The CSV may contain only a header, unavailable intervals, or another process."
        }
    } finally { $reader.Dispose() }
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
    $diagnosticPath = $output + '.presentmon.log'
    if (Test-Path -LiteralPath $diagnosticPath) { throw "Capture diagnostics already exist: $diagnosticPath. Choose a new output file to preserve previous diagnostics." }
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
    $diagnosticsWritten = $false
    # Reserve the sidecar atomically before starting capture. Existing logs are
    # never truncated, even when two callers request the same output name.
    $diagnosticFile = [IO.File]::Open($diagnosticPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $diagnosticWriter = New-Object IO.StreamWriter($diagnosticFile, (New-Object Text.UTF8Encoding($false)))
    try {
        $diagnosticWriter.AutoFlush = $true
        $diagnosticWriter.WriteLine("PresentMon: $executable")
        $diagnosticWriter.WriteLine("Target PID: $ProcessId; ETW session: $session")
        $capture = Start-ZeroStutterCaptureProcess -Executable $executable -Arguments $arguments
        $deadline = [DateTime]::UtcNow.AddSeconds($Seconds + $DelaySeconds + 30)
        while (-not $capture.Process.WaitForExit(200)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'PresentMon exceeded the capture timeout.' }
        }
        $stdout = $capture.Output.GetAwaiter().GetResult()
        $stderr = $capture.Error.GetAwaiter().GetResult()
        $details = $stdout + [Environment]::NewLine + $stderr
        $diagnosticWriter.WriteLine("Exit code: $($capture.Process.ExitCode)")
        $diagnosticWriter.WriteLine("[stdout]`r`n$stdout`r`n[stderr]`r`n$stderr")
        $diagnosticsWritten = $true
        if ($details -match '(?im)^\s*(?:warning|error)\s*:') { Write-Warning "PresentMon diagnostics (saved to $diagnosticPath): $($details.Trim())" }
        if ($capture.Process.ExitCode -ne 0) { throw "PresentMon exited with code $($capture.Process.ExitCode). $($details.Trim())" }
        # PresentMon 2.x reports ETW loss and overflow as warnings while returning
        # zero. Those captures cannot establish reliable frame-time tails.
        # https://github.com/GameTechDev/PresentMon/blob/v2.6.0/PresentMon/MainThread.cpp
        $lossPattern = '(?i)\b0*[1-9]\d*\s+ETW\s+(?:buffers?|events?)\s+(?:were\s+)?lost\b|\b0*[1-9]\d*\s+overflowed\s+present\s+events?\b|\b(?:EventsLost|BuffersLost|OverflowedPresents)\s*=\s*0*[1-9]\d*\b'
        if ($details -match $lossPattern) { throw "PresentMon reported lost ETW data or overflowed presents. Capture rejected; retain '$output' and '$diagnosticPath' for inspection and repeat the run." }
        if (-not (Test-Path -LiteralPath $output -PathType Leaf) -or (Get-Item -LiteralPath $output).Length -eq 0) { throw "PresentMon created no frame capture. Confirm the target is presenting frames and that your account has ETW capture access. $($details.Trim())" }
        Assert-ZeroStutterCaptureData -Path $output -ProcessId $ProcessId
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
            try {
                if (-not $capture.Process.HasExited) { $capture.Process.Kill(); [void]$capture.Process.WaitForExit(5000) }
                if (-not $diagnosticsWritten -and $capture.Process.HasExited) {
                    $diagnosticWriter.WriteLine("Capture did not complete. Exit code: $($capture.Process.ExitCode)")
                    $diagnosticWriter.WriteLine("[stdout]`r`n$($capture.Output.GetAwaiter().GetResult())`r`n[stderr]`r`n$($capture.Error.GetAwaiter().GetResult())")
                }
            } finally { $capture.Process.Dispose(); $diagnosticWriter.Dispose() }
        } else {
            $diagnosticWriter.Dispose()
        }
    }
}

Export-ModuleMember -Function Get-ZeroStutterFrameReport, Compare-ZeroStutterFrameReport, Invoke-ZeroStutterCapture
