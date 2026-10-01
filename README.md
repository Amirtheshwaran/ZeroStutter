# ZeroStutter

A small, opt-in Windows process monitor. ZeroStutter watches a list of executable names and shows whether matching programs are running.

It is **read-only by default**. If you deliberately configure a profile as `AboveNormal` and launch with `-ApplyProfilePriorities`, ZeroStutter temporarily changes that process priority and tries to restore the original value when you quit normally.

ZeroStutter does not promise higher FPS or fix every stutter. It does not clear the standby list, change timer resolution, set CPU affinity, edit the registry, or change your power plan.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-blue.svg)](#requirements)

## What it does

- Scans running processes for the executable names in `profiles.json`.
- Displays each match and its current process priority.
- Optionally sets a selected process to `AboveNormal` for the lifetime of the monitor.
- Restores the original priority on normal exit, unless another program changed it in the meantime.
- Requires no administrator rights, background service, third-party modules, telemetry, or network access at runtime.

The operating system already manages memory caching, timer resolution, and CPU scheduling. This project leaves those decisions to Windows. A process-priority change can help in some workloads and hurt in others; compare results on your own system.

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1 or PowerShell 7.
- Run as your normal user. Administrator rights are not needed.
- The live dashboard needs an interactive console; use `-Once` for automation or redirected sessions.

## Run from a checkout

Download or clone the repository, inspect the files, then open PowerShell in the project folder:

```powershell
.\ZeroStutter.ps1
```

Press `Q` to quit. To run a read-only, one-time scan:

```powershell
.\ZeroStutter.ps1 -Once
```

The scan reports matching processes and exits without changing their settings.

## Optional temporary priority changes

All included profiles are `Observe` only. To try a temporary priority adjustment:

1. Open `profiles.json` and change only the selected profile's `priorityClass` from `Observe` to `AboveNormal`.
2. Start ZeroStutter with the explicit opt-in:

```powershell
.\ZeroStutter.ps1 -ApplyProfilePriorities
```

3. Quit with `Q` or Ctrl+C. ZeroStutter restores each process's original priority if it is still running and still has the value ZeroStutter set.

This is an experiment, not a performance guarantee. Avoid using it with software whose rules prohibit process-tuning utilities. A forced termination, system crash, or power loss can prevent cleanup; a target process may then keep `AboveNormal` until it exits. Profiles already at `AboveNormal`, `High`, or `RealTime` are left alone.

## Optional local install

The installer copies the checked-out files to `%LOCALAPPDATA%\ZeroStutter` and creates a desktop shortcut. A valid existing `profiles.json` is preserved; if an older or invalid file needs replacement, the installer saves a timestamped backup first. It does not download or execute code from the internet, elevate privileges, edit PATH, or start the monitor automatically.

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\install.ps1
```

To remove the files installed by this script:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "$env:LOCALAPPDATA\ZeroStutter\uninstall.ps1"
```

You can also run the project directly from the checkout and skip installation.

## Profiles

Each profile includes a display name, executable file name, category, and priority mode. Executable matching is case-insensitive and uses the process name; ZeroStutter does not inspect or inject into game processes.

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
- `AboveNormal`: eligible for the explicit `-ApplyProfilePriorities` option.

The profile schema is in `schema/profiles.schema.json`.

## Safety and privacy

- No process memory is read or written.
- No files are downloaded by the running monitor.
- No registry, timer-resolution, CPU-affinity, or power-plan setting is changed.
- Protected processes or processes owned by another user may be visible only partially; ZeroStutter skips changes it cannot apply.
- Only a normal exit can run cleanup. Forced termination can leave a selected process at the temporary priority until that process exits.

## Validation

Run the dependency-free checks from the repository root:

```powershell
pwsh -NoProfile -File .\tests\Validate-Project.ps1
```

The checks parse the PowerShell files, validate profiles against the schema, exercise process matching and priority restoration, and test install, profile-preservation, backup, and uninstall behavior in a temporary directory. They do not modify live process settings.

## License

MIT. See [LICENSE](LICENSE).
