# Roadmap

ZeroStutter aims to make Windows scheduling experiments easy to run, reverse, and evaluate. It is experimental. Priorities below describe proposed work, not promised performance gains or release dates.

Contributions are welcome from developers and people willing to run repeatable tests on their own hardware. Read [CONTRIBUTING.md](CONTRIBUTING.md), then use [issues](https://github.com/Amirtheshwaran/ZeroStutter/issues) to discuss a focused change or share a result.

## Current scope

- Sessions for one process instance, with priority and HighQoS controls.
- Optional CPU Sets based on reported topology and temporary AC core-parking changes.
- Restoration and recovery journals that account for later external changes.
- PresentMon capture, diagnostic logs, and comparison of frame-interval distributions.
- PowerShell 5.1 and 7 validation and portable packaging.
- A native Windows desktop executable for process selection, reversible sessions, capture, and report inspection.

These capabilities need separate compatibility and performance evidence for each game and hardware configuration. API correctness, successful launch, and improved frame pacing are different outcomes.

## Next priorities

| Priority | Work | Completion criteria |
| --- | --- | --- |
| 1 | [Repeatable real-game evidence (#3)](https://github.com/Amirtheshwaran/ZeroStutter/issues/3) | Record the scene, setup, exact options, run order, per-run results, and restoration outcome. Include improvements, regressions, and unchanged results. |
| 1 | [Capture quality and scene selection (#1)](https://github.com/Amirtheshwaran/ZeroStutter/issues/1) | Make invalid captures clear and support consistent timestamp-based gameplay segments without silently trimming slow frames. |
| 1 | Recovery and compatibility coverage | Expand reproducible checks for access failures, interrupted sessions, processor groups, and supported power-policy variations. |
| 2 | [Multiple-run comparison (#2)](https://github.com/Amirtheshwaran/ZeroStutter/issues/2) | Summarize matched baseline/tuned runs, their variability, and exclusions without presenting one run as proof. |
| 2 | [Guided capture setup (#4)](https://github.com/Amirtheshwaran/ZeroStutter/issues/4) | Explain the selected process, supported PresentMon console options, ETW permissions, and output paths before recording. |
| 2 | [Release reproducibility (#5)](https://github.com/Amirtheshwaran/ZeroStutter/issues/5) | Tie portable packages and checksums to exact source tags and passing validation. Keep third-party tools separately sourced. |

## Useful first contributions

- Reproduce a reported command or installation problem and improve its error message.
- Verify a game's executable name and add an observation-only profile.
- Improve a setup or recovery example after following it on a fresh extraction.
- Add a small deterministic fixture for a measurement edge case.
- Submit a complete baseline/tuned report, including when tuning makes no difference.

## Boundaries

The project will not advertise universal stutter elimination or hardware-independent FPS gains. New controls need a documented mechanism, explicit user selection, restoration, and a practical measurement plan. Features that weaken antivirus protection, guess CPU placement, or treat cache removal as evidence of smoother frames are outside the current direction.

Requests for new controls should explain which observed problem they address and how a contributor could verify the result. A smaller tool with clear evidence is a useful contribution to gaming and Windows performance work.
