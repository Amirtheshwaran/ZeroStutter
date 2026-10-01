# ZeroStutter

A small, opt-in Windows gaming performance helper. ZeroStutter watches configured processes, samples their CPU use and working-set memory, and can temporarily adjust CPU scheduling priority when you choose.

It is **read-only by default**. You can explicitly configure a game as `AboveNormal` or a CPU-heavy background app as `BelowNormal`, then launch with `-ApplyProfilePriorities` to apply the change for that run.

Priority changes affect CPU scheduling only. They cannot fix a GPU bottleneck, disk or network stalls, thermal throttling, or a game's own frame-pacing problems. Results depend on the workload; this tool does not promise higher FPS or eliminate stutter. It does not clear the standby list, change timer resolution, set CPU affinity, edit the registry, or change your power plan.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-blue.svg)](#requirements)

## What it does

- Scans running processes for the executable names in `profiles.json`.
- Displays each match, current priority, sampled CPU percentage, and working-set memory.
- Optionally sets a selected process to `AboveNormal` or `BelowNormal` for the monitor session.
- Restores the original priority on normal exit, unless another program changed it in the meantime.
- Requires no administrator rights, background service, third-party modules, telemetry, or network access at runtime.

The CPU percentage is sampled between dashboard refreshes and normalized across logical processors. Working-set memory is RAM currently resident for that process; it is not VRAM or total committed memory. Windows documents process priority as a CPU scheduling input, not a frame-rate control. Raising a game's priority or lowering a known CPU-heavy background task may help during CPU contention, but it does not control disk, network, or GPU work and can hurt responsiveness or audio. Change one profile at a time and compare the same workload before and after with a frame-time tool. Keep a change only if repeated runs show a consistent improvement. See Microsoft's [process priority documentation](https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-setpriorityclass).

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1 or PowerShell 7.
- Run as your normal user. Administrator rights are not needed.
- The live dashboard needs an interactive console; use `-Once` for automation or redirected sessions.

## Run from a checkout

Download or clone the repository, inspect the files, then open PowerShell in the project folder. On Windows PowerShell 5.1, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ZeroStutter.ps1
```

If PowerShell 7 is installed, replace `powershell.exe` with `pwsh.exe`. The execution-policy option applies only to the launched PowerShell process; it does not save a policy change. A policy enforced by Group Policy can still take precedence. See Microsoft's [execution policy documentation](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_execution_policies).

Press `Q` to quit. To run a read-only, one-time scan:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ZeroStutter.ps1 -Once
```

The scan reports matching processes and exits without changing their settings.

## Optional temporary priority changes

All included profiles are `Observe` only. To try a temporary CPU scheduling adjustment:

1. Open `profiles.json` and change only one selected profile's `priorityClass` from `Observe` to `AboveNormal` for a game, or `BelowNormal` for a CPU-heavy background app you have identified.
2. Start ZeroStutter with the explicit opt-in:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ZeroStutter.ps1 -ApplyProfilePriorities
```

3. Quit with `Q` or Ctrl+C. ZeroStutter restores each process's original priority if it is still running and still has the value ZeroStutter applied.

This is an experiment, not a performance guarantee. Avoid using it with software whose rules prohibit process-tuning utilities. A forced termination, system crash, or power loss can prevent cleanup; a target process may then keep the selected priority until it exits. Profiles already at the requested priority are left unchanged, and other non-standard priorities are preserved.

## Optional local install

The installer copies the checked-out files to `%LOCALAPPDATA%\ZeroStutter` and creates a desktop shortcut. A valid existing `profiles.json` is preserved; if an older or invalid file needs replacement, the installer saves a timestamped backup first. It does not download or execute code from the internet, elevate privileges, edit PATH, or start the monitor automatically.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

To remove the files installed by this script:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ZeroStutter\uninstall.ps1"
```

You can also run the project directly from the checkout and skip installation.

## Profiles

Each profile includes a display name, executable file name, category, and priority mode. Executable matching is case-insensitive and uses the process name; ZeroStutter does not inspect or inject into game processes.

A profile applies to every running process with that executable name. Common names such as `node.exe` can match multiple unrelated apps, so keep those profiles in `Observe` unless you intend to tune every matching process.

```json
{
  "name": "Example game",
  "executable": "example.exe",
  "category": "Game",
  "priorityClass": "Observe"
}
```

Allowed priority modes:

- `Observe`: show a matching process without changing it.
- `AboveNormal`: raise a normal or below-normal process for the explicit `-ApplyProfilePriorities` option.
- `BelowNormal`: lower a normal-priority process for the explicit `-ApplyProfilePriorities` option.

The profile schema is in `schema/profiles.schema.json`.

## Safety and privacy

- No process memory contents are read or written. The dashboard reads process metadata and working-set counters only.
- No files are downloaded by the running monitor.
- No registry, timer-resolution, CPU-affinity, or power-plan setting is changed.
- Protected processes or processes owned by another user may be visible only partially; ZeroStutter skips changes it cannot apply.
- Only a normal exit can run cleanup. Forced termination can leave a selected process at the temporary priority until that process exits.

## Validation

Run the dependency-free checks from the repository root in Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Validate-Project.ps1
```

If PowerShell 7 is installed, replace `powershell.exe` with `pwsh.exe`.

The checks parse the PowerShell files, validate profiles against the schema, exercise CPU sampling and priority restoration, test a priority change on a temporary PowerShell child process, and test install, profile-preservation, backup, and uninstall behavior in a temporary directory. They do not modify settings on your other apps or system power, registry, timer, or affinity settings.

## License

MIT. See [LICENSE](LICENSE).
