# Contributing

ZeroStutter is an experimental Windows frame-pacing toolkit. Contributions to code, documentation, compatibility testing, and reproducible benchmarks are welcome. An unchanged result or regression is useful evidence.

Keep every tuning control explicit, reversible, and measurable. The monitor remains read-only unless the user opts in. Passing correctness tests does not establish that a setting improves a game.

## Find a contribution

Read the [roadmap](ROADMAP.md) and [open issues](https://github.com/Amirtheshwaran/ZeroStutter/issues). For a substantial feature, open an issue describing the problem, proposed behavior, and how you will check it. Small fixes and documentation corrections can go directly into a pull request.

Use the bug form for broken behavior and the performance form for a measured game result. Include the command and version used. Review logs before uploading: reports can contain executable names, user names, and local paths. Do not attach saves, account tokens, or proprietary game files.

## Local development

1. Fork and clone the repository. Work on a branch for your change.
2. Use Windows 10 version 1709 or newer, or Windows 11. The runtime supports Windows PowerShell 5.1 and PowerShell 7; maintain compatibility with both.
3. Edit the scripts directly. There is no package-manager setup or third-party PowerShell module requirement. Native interop source is compiled by `Add-Type` when needed.
4. Run the relevant focused tests, then the complete suite before submitting:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Validate-Project.ps1
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Validate-Project.ps1
```

The execution-policy option applies to that PowerShell process. Organization policy can still override it. If one shell is unavailable, state which checks you ran; CI covers both. The capture tests compile a harmless console fixture using the Windows .NET Framework C# compiler. They do not require PresentMon, a game, or an ETW session.

To inspect a portable package, choose a new output directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-Package.ps1 -OutputDirectory .\dist\local-review
```

The build refuses to overwrite an existing archive. Generated packages, captures, and logs do not belong in source commits.

### Where changes belong

| Area | Files |
| --- | --- |
| Windows desktop app and executable build | `src/ZeroStutter.Desktop.cs`, `Build-Desktop.ps1`, `tests/Test-Desktop.ps1` |
| Entrypoint, launcher, process monitor | `ZeroStutter.ps1`, `Launch-ZeroStutter.ps1`, `src/ZeroStutter.Core.psm1` |
| Game sessions and recovery | `Start-ZeroStutterSession.ps1`, `Restore-ZeroStutterSession.ps1`, `src/ZeroStutter.Recovery.psm1` |
| Native process controls and topology | `src/ZeroStutter.Native.cs`, `src/ZeroStutter.Tuning.psm1` |
| Temporary power-plan controls | `src/ZeroStutter.Power.psm1` |
| Capture and frame statistics | `Measure-ZeroStutter.ps1`, `src/ZeroStutter.Measurement.psm1` |
| Profiles and validation | `profiles.json`, `schema/profiles.schema.json`, `tests/` |

## Requirements for code changes

- Use documented Windows APIs and actual CPU topology. Explain the expected benefit and limitations of a new control.
- Save the original state before changing it. Identify a target by PID and creation time. Preserve settings changed by another application after ZeroStutter applied its values.
- Cover normal shutdown, partial application failure, access denied, target exit, PID reuse, and owner-crash recovery when relevant. Routine native tests must target disposable child processes.
- Mock power mutations in routine tests. `tests\Test-Session.ps1 -IncludePowerPlan` is an explicit hardware check that changes the active plan temporarily; run it only when you intend to exercise that path and inspect restoration afterward.
- Keep read-only discovery usable without administrator rights. Do not add self-elevation, persistent startup behavior, or new network activity implicitly.
- Keep desktop work asynchronous. A window close must request restoration, and an unexpected UI exit must end its owned session. Preserve PID and creation-time checks when connecting UI controls to the backend.
- Do not add working-set trimming, memory purges, guessed CPU masks, automatic antivirus exclusions, undocumented timer tweaks, or edits to the user's original power plan.
- Preserve the MIT license in distributions. Attribute new third-party source and review its redistribution terms. PresentMon is obtained separately; do not commit its binaries.

## Reproducible game measurements

Use the capture commands in the [README](README.md#measure-whether-it-helps). A useful report includes:

1. **Setup:** game/version, repeatable scene or built-in benchmark, CPU/GPU/RAM, Windows build, graphics driver, graphics settings, resolution, cap, VSync/VRR, frame generation, AC/battery state, and relevant background workload.
2. **Configuration:** ZeroStutter commit or release, PresentMon version, exact commands, and which settings were successfully applied. Test one optional control at a time.
3. **Procedure:** finish shader compilation and complete an unmeasured warm-up. Keep focus, settings, and scene fixed. Capture at least three baseline and three tuned runs, alternating order, for example `A B / B A / A B`. Verify restoration between configurations.
4. **Comparable intervals:** measure the same gameplay segment. Exclude menus and loading screens by a rule chosen before comparing results. Do not remove frames because they look slow. `-SkipFirstFrames` skips rows, not seconds, and is not a general method of aligning runs.
5. **Results:** retain each raw CSV, its `.presentmon.log` sidecar, and the analysis JSON. Report per-run p99, p99.9, slow-frame percentage, frame count, metric column, and excluded rows. Show paired changes and their spread; do not treat thousands of frames in one run as thousands of independent trials.

Start the initial comparison with frame generation disabled if practical, and record that choice. Present-call intervals and displayed-frame duration answer different questions. Use the same metric for both configurations. A threshold such as 33.333 ms is a chosen frame budget, not a universal definition of stutter.

Reject captures reporting lost ETW data or overflowed presents. Keep those files for troubleshooting. Very short runs make tail percentiles sensitive to individual frames; extend captures and repeat before claiming an improvement. Publish neutral and negative results alongside improvements. A change in average FPS alone does not demonstrate reduced stutter.

## Known limitations worth testing

- A successful Windows API call does not prove a game's own threads use the requested scheduling policy. CPU Sets are preferences; thread-specific settings and hard affinity may take precedence.
- Performance-core selection requires distinct efficiency classes. AMD V-Cache CCD placement cannot be inferred from logical processor numbering.
- Protected games may deny access. Report that behavior without attempting to bypass protection.
- Recovery depends on the saved journal, permissions, and identifiable owned state. A reboot can leave a temporary power plan requiring `-Recover`.
- Scheduling controls do not resolve every cause of shader, streaming, GPU, driver, thermal, or network stalls. Game-specific benefit must be measured.

## Adding a profile

Add a unique executable name to `profiles.json`. Use `Observe` by default. The JSON schema is `schema/profiles.schema.json`. Process names may differ from the executable filename; confirm the actual Windows process name before adding a profile.

## Pull requests

Keep each pull request focused. Describe the problem, behavior changed, checks run, and remaining uncertainty. Add regression coverage for a code fix and update user-facing commands when behavior changes. For performance claims, link the reproducible report rather than extrapolating from a timer readout, memory counter, or synthetic fixture.
