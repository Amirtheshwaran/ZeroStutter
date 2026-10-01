# ZeroStutter

**Reversible game tuning with measurable frame pacing.**

ZeroStutter helps you try Windows scheduling changes that can reduce CPU-related frame-time spikes, then compare captures to see whether they help your game. Start a session for one running game, try one setting at a time, and keep only changes that improve repeated runs.

[![CI](https://github.com/Amirtheshwaran/ZeroStutter/actions/workflows/ci.yml/badge.svg)](https://github.com/Amirtheshwaran/ZeroStutter/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-blue.svg)](#requirements)

**Status: experimental.** Native settings and recovery are tested on temporary processes; there are no published game-performance results yet. Shader compilation, asset streaming, GPU saturation, drivers, thermals, and network stalls need their own fixes. No utility can promise to eliminate every kind of stutter.

## Start here

1. Download the repository with **Code > Download ZIP**, then extract it completely (or clone it).
2. Start your game.
3. Double-click **`Start-ZeroStutter.cmd`**, choose **1**, and enter the game's executable name, such as `cs2.exe`. Use Task Manager > Details to find it.
4. Start with the default session. Leave the extra CPU/core-parking experiments off for your first comparison.
5. Press **Q** in the session window to restore and stop. Closing the game also ends its session.

The launcher offers a process monitor, CPU topology inspection, and recovery. Installation is optional. Nothing starts at Windows login.

From PowerShell in the extracted folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ZeroStutter.ps1 -Game cs2
```

The default game session requests **AboveNormal CPU priority** and **HighQoS** for that process. A read-only monitor is still available by running `ZeroStutter.ps1` without `-Game`. The included `profiles.json` entries all remain observation-only.

## What each control does

| Control | Behavior | When to try it |
| --- | --- | --- |
| Default game session | Requests AboveNormal priority and disables execution-speed power throttling for the selected process | CPU scheduling contention or an application classified for power saving |
| `-CpuPolicy Performance` | Selects CPU Sets in the highest efficiency class reported by Windows | A hybrid CPU where the game performs worse when scheduled across core types |
| `-UnparkCores` | Clones the active power plan, sets the supported minimum-unparked-core settings to 100% on AC, then restores the original plan | Testing whether core parking contributes to spikes; may increase heat and power use |
| `-DisableHighQoS` / `-Priority Observe` | Independently disables either default adjustment | Isolating which setting actually helps |
| `Measure-ZeroStutter.ps1` | Captures with a supplied PresentMon console executable; analyzes and compares CSV files | Establishing a baseline and checking frame-time tails |

CPU Sets are **soft scheduling preferences**: a game's thread-specific settings, hard affinity, or processor groups can take precedence. ZeroStutter uses actual topology, skips CPUs reserved for another process, and rejects the Performance policy when distinct core classes cannot be identified. It does **not** infer an AMD V-Cache CCD from processor numbering. [Microsoft CPU Sets documentation](https://learn.microsoft.com/windows/win32/procthread/cpu-sets).

HighQoS changes the selected process's execution-speed throttling policy. It does not lock CPU frequency. Core unparking does not disable every CPU idle state. Priority changes can also hurt other work, audio, or responsiveness; use comparisons to choose settings. [Power throttling](https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessinformation), [core parking](https://learn.microsoft.com/windows-hardware/customize/power-settings/options-for-core-parking-cpmincores).

## Session commands

Use `pwsh.exe` instead of `powershell.exe` if you prefer PowerShell 7. The execution-policy option is scoped to that host process; organization policy can still override it.

```powershell
# Choose a specific PID if several processes share the same executable name
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ZeroStutter.ps1 -TargetProcessId 1234

# Try performance cores (requires distinct efficiency classes reported by Windows)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ZeroStutter.ps1 -Game cs2 -CpuPolicy Performance

# Try AC core unparking independently of priority and HighQoS
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ZeroStutter.ps1 -Game cs2 -UnparkCores -Priority Observe -DisableHighQoS

# Run without dashboard updates for 120 seconds; save settings and cleanup results
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ZeroStutter.ps1 -Game cs2 -Headless -Seconds 120 -ReportPath .\session.json

# Read-only discovery
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ZeroStutter.ps1 -Topology
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ZeroStutter.ps1 -Once
```

Replace `1234` with your actual game PID. A session targets that process instance only: it never follows a recycled PID or automatically tunes every copy of an executable. A relaunched game requires a new session. Headless mode ends when the game exits or the requested duration expires; it is not an installed service. Keep its host open while playing.

## Measure whether it helps

Obtain the **PresentMon console executable** from [Intel's official releases](https://github.com/GameTechDev/PresentMon/releases). ZeroStutter does not bundle or download PresentMon. It executes the local executable you explicitly supply and checks for the required console options. PresentMon capture requires ETW access (an administrator shell or appropriate Performance Log Users membership); ordinary tuning does not self-elevate. [PresentMon documentation](https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md).

1. Warm up the same game scene or built-in benchmark. Keep graphics settings, resolution, frame cap, frame generation, and background workload fixed.
2. **Without a ZeroStutter tuning session**, capture the baseline in a separate PowerShell window. Replace the executable path and PID:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Measure-ZeroStutter.ps1 -Capture -PresentMonPath "C:\Tools\PresentMon.exe" -ProcessId 1234 -Seconds 60 -DelaySeconds 5 -OutputPath .\baseline.csv
```

3. Start a ZeroStutter game session, repeat the same scene, and capture again using `-OutputPath .\candidate.csv`.
4. Compare:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Measure-ZeroStutter.ps1 -BaselinePath .\baseline.csv -CandidatePath .\candidate.csv -JsonPath .\comparison.json
```

The report includes mean, p50, p95, p99, p99.9, maximum interval, and the fraction above a configurable threshold (default **33.333 ms**). For example, `-SlowFrameThresholdMs 16.667` tests a different frame budget. Lower tail intervals and fewer slow frames are useful signals; one pair of runs cannot establish causation. Alternate baseline/tuned order and collect at least three runs per configuration.

### Metric definitions

- Default captures request PresentMon's `--v1_metrics` format. `PresentToPresent` uses **`msBetweenPresents`**: intervals between application Present calls, including presents that were not displayed. This is application submission pacing, not display latency or GPU execution time.
- `-Metric Displayed` uses **`DisplayedTime`** in a compatible modern capture, or **`msBetweenDisplayChange`** in a legacy capture. These two definitions cannot be compared with each other.
- Percentiles use nearest rank: `sorted[ceil(percentile * count) - 1]`. No automatic outlier removal or invented FPS improvement.
- Unavailable, nonpositive, nonfinite, and invalid intervals are counted and excluded. Displayed analysis also excludes undisplayed intervals. Review exclusion counts.
- Optional `-SkipFirstFrames N` removes N rows from the selected stream before validation, consistently for both captures.
- Multiple processes or swap chains require explicit selection. The error lists available streams. Use `-BaselineProcessId`, `-CandidateProcessId`, `-BaselineSwapChain`, and `-CandidateSwapChain` for comparisons, or `-ProcessId` / `-SwapChainAddress` with `-CsvPath`.
- Existing CSV/JSON output files are never intentionally overwritten. Each live capture uses its own ETW session name.

## Restoration and interrupted sessions

A game session saves original settings before applying changes. Normal shutdown restores settings only when they still match the values ZeroStutter applied, preserving different values selected afterward. A small separate PowerShell recovery helper watches the session owner and attempts cleanup if that owner is killed. Recovery validates the PID **and process creation time**.

Power changes use a named, temporary copy of the current plan. The original plan and battery settings are untouched. Cleanup switches back only if the temporary plan is still active, then deletes the owned temporary plan. A later plan switch is preserved. Power recovery journals are retained when cleanup cannot finish.

If the PC restarts, both processes are killed together, permissions change, or recovery reports an error, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ZeroStutter.ps1 -Recover
```

State is stored under `%LOCALAPPDATA%\ZeroStutter\State`. If you used `-StateDirectory`, supply the same directory when recovering. Do not delete journals before recovery. Process settings disappear when that target exits; a temporary power plan can survive a restart. Recovery cannot guarantee restoration when Windows denies access or an ownership label was changed.

## Install, update, or remove

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ZeroStutter\uninstall.ps1"
```

The installer copies scripts, native source, README, and MIT license to `%LOCALAPPDATA%\ZeroStutter`, and creates a menu shortcut. Close sessions before updating. Valid profiles are preserved; incompatible profiles are backed up. Uninstall attempts recovery first and keeps unknown files, reports, and backups.

The legacy `-ApplyProfilePriorities` monitor mode reads `Observe`, `AboveNormal`, or `BelowNormal` from `profiles.json`. It applies to **every** process with the listed name and has normal-exit restoration only. Prefer a game session for one chosen process and crash recovery. Common names such as `node.exe` may identify unrelated applications.

## Requirements and boundaries

- Windows 10 version 1709 or newer, or Windows 11; Windows PowerShell 5.1 or PowerShell 7.
- Normal-user access to the selected application. Protected games may deny changes; ZeroStutter reports failure and does not bypass protection. Check the game's rules before using external tuning software.
- Power-plan changes depend on the device's available policies and permissions. Some managed or Modern Standby systems may reject them.
- No injection, process-memory scanning, driver, telemetry, login task, or automatic network downloads.
- No standby-list purges, working-set trimming, Defender exclusions, or undocumented registry timer bypasses. Cached standby memory is available memory; clearing it is not proof of smoother frames. A timer-resolution readout is not a frame-time benchmark. [Microsoft memory terminology](https://learn.microsoft.com/windows-hardware/test/assessments/results-for-the-memory-footprint-assessment).

## Development and validation

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Validate-Project.ps1
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Validate-Project.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-Package.ps1
```

Tests cover real priority, CPU Set, and HighQoS changes on temporary child processes; JSON recovery; termination of a session owner; preserving external changes; mocked power-plan failure/recovery paths; capture argument/cleanup fixtures; frame statistics; profile validation; and installation/removal. Routine tests do not change the host power plan or tune your other applications. Synthetic frame data tests arithmetic, not gaming performance. Hybrid selection has synthetic coverage and is exercised natively only on hardware that exposes distinct classes.

For an explicit hardware integration check, `tests\Test-Session.ps1 -IncludePowerPlan` also activates a temporary power-plan copy for two seconds and verifies restoration. It needs permission to create and activate power plans. This check is excluded from routine CI.

CI runs both shells and builds a portable ZIP with a SHA-256 checksum as a workflow artifact. The local build writes to `dist`; choose a new `-OutputDirectory` for another build.

See [CONTRIBUTING.md](CONTRIBUTING.md). When reporting performance, include the game, CPU/GPU, Windows build, settings, exact ZeroStutter options, repeated captures, and failures as well as successes. Reports can contain application names and local paths; inspect them before sharing.

## License

[MIT](LICENSE). PresentMon is a separate Intel open-source project with its own license and distribution. ZeroStutter includes no third-party binary or copied PresentMon source.
