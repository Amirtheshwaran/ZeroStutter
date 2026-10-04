# Cyberpunk 2077 gameplay check — 2026-10-02

## Result

ZeroStutter successfully applied its default session settings to a running copy of Cyberpunk 2077 and restored the original settings afterward. The game continued running throughout both captures. This supports **functional compatibility of the default session on this PC**.

**This test does not demonstrate a performance improvement.** The tuned recording had worse frame intervals, and its presentation mode changed repeatedly. The two recordings also lacked a repeatable camera position or movement route. They cannot establish that ZeroStutter caused either an improvement or a regression. This evidence supports continued experimental testing; it does not justify a claim that ZeroStutter eliminates stutter.

## Setup

| Item | Configuration |
| --- | --- |
| Game | Cyberpunk 2077, product version 2.31, Steam |
| CPU | AMD Ryzen 7 7800X3D, 8 cores / 16 logical processors |
| GPU | AMD Radeon RX 9070 XT, Windows driver 32.0.31044.16 |
| Memory / OS | 32 GB installed; Windows 11 Home, build 26200 |
| Graphics | 2560 × 1440 fullscreen, custom preset, texture quality High |
| Scaling / frame generation / ray tracing | Off / off / off |
| VSync / in-game frame cap | Off / disabled |
| Scene | Regular gameplay outside the garage in Lightning Breaks, at night |
| Capture | PresentMon 2.6.0, legacy metrics; 45 seconds after a 5-second delay |
| Order | A1: baseline, then B1: default ZeroStutter session; one pair |
| Source | Session code based on commit `985cbb74ffe9db9dda024324f6171e20c22a37f1`, with local capture-validation fixes |

The baseline and tuned captures came from the same game process and swap chain. The game settings file had the same SHA-256 before testing and after the session. This verifies that its contents were unchanged; it does not prove that focus, scene complexity, background activity, or operating-system conditions were identical.

Power-plan state was not recorded alongside each capture and was not controlled. Core unparking was disabled. No CPU-set restriction was requested. Older benchmark recordings and tests from October 1 are not included.

## Settings applied and restored

Independent process-state reads were taken before the session, during the session, at the end of capture, and after cleanup.

| Setting | Before B1 | During B1 and at capture end | After cleanup |
| --- | --- | --- | --- |
| Process priority | Normal | AboveNormal | Normal |
| Power-throttling control / state masks | `0 / 0` | `1 / 0` | `0 / 0` |
| Selected CPU sets | None | None | None |

The power-throttling masks show that the execution-speed throttling override was applied with throttling disabled, which is the session's HighQoS request. They do not measure actual CPU frequency or scheduling latency. A1 remained at Normal priority with its original masks throughout.

The B1 session ended on its configured duration. Its cleanup report reported successful restoration, no cleanup errors, and unchanged CPU sets. The independent post-session read confirmed restoration while the game was still running.

## Recorded frame intervals

These figures use `msBetweenPresents`: time between consecutive application Present calls, **including calls whose frames were not displayed**. They describe submission pacing, not display latency or GPU execution time. Percentiles use nearest rank, `sorted[ceil(p × count) − 1]`, without interpolation. Lower interval values mean shorter waits between calls.

| Metric | A1: baseline | B1: default session |
| --- | ---: | ---: |
| CSV rows / valid intervals | 4,127 / 4,127 | 3,820 / 3,820 |
| Invalid intervals excluded | 0 | 0 |
| Rows skipped | 0 | 0 |
| Sum of intervals | 44.979 s | 44.957 s |
| Mean | 10.899 ms | 11.769 ms |
| Median | 10.891 ms | 11.161 ms |
| 95th percentile | 11.629 ms | 12.529 ms |
| 99th percentile | 12.058 ms | 22.234 ms |
| 99.9th percentile | 12.906 ms | 227.836 ms |
| Maximum | 13.656 ms | 247.558 ms |
| Intervals greater than 33.333 ms | 0 (0.000%) | 18 (0.471%) |

Every recorded valid interval was retained, including the long intervals. There was no outlier trimming, scene cropping, or removal of display-mode transitions. The tuned recording's mean was 7.98% higher and its 99th percentile was 84.40% higher. Those are descriptive differences between these two recordings, not estimates of the software's effect.

## Why this pair cannot measure the tuning effect

The display path differed substantially:

| PresentMon observation | A1 | B1 |
| --- | ---: | ---: |
| Hardware: Independent Flip rows | 4,127 | 749 |
| Composed: Flip rows | 0 | 3,071 |
| Rows marked `Dropped` | 0 | 2,024 |

In B1, presentation mode changed approximately 6.87, 19.02, 19.65, 21.46, and 22.40 seconds after the requested capture start. Its intervals above 33.333 ms clustered around 7.11–7.46 seconds and 18.85–22.82 seconds. This indicates different presentation conditions during the captures. The trace does not establish the reason for those changes. In particular, `Dropped` is a PresentMon frame-display flag; it is not a count of lost ETW events.

The camera changed, foreground focus was not controlled, and no repeated movement route was recorded. There was only one pair, always baseline first, with no dedicated excluded warm-up or counterbalanced repetitions. Background load and power-plan state were not logged per trial. These limitations prevent attributing the recorded differences to ZeroStutter.

## Capture integrity and reproducibility

Both PresentMon processes exited with code 0, and both logs reported recording start and stop. Neither log reported lost ETW events, lost buffers, or overflow. Both emitted the same non-elevated-process-query warning about short-lived processes or processes on other accounts. The intended already-running game was targeted by process ID and was identified correctly in every row. The analyzer accepted one stream per capture.

This test exposed a measurement usability gap: the original analyzer did not flag presentation-mode changes or dropped presents. The updated analyzer now includes optional presentation diagnostics and warns about B1's mixed modes, 2,024 dropped presents (52.98% of known flags), and the differing presentation-mode distributions across this pair. Unknown optional diagnostic values are counted explicitly. The same recorded intervals still produce the statistics above; the fix does not trim or alter them.

The [sanitized metrics JSON](2026-10-02-cyberpunk.json) includes the exact computed values, source CSV hashes, capture diagnostics, and restoration evidence. Raw traces, machine-specific paths, process identifiers, screenshots, and save files are not published. The exact metric definitions are implemented in [ZeroStutter.Measurement.psm1](../../src/ZeroStutter.Measurement.psm1).

Before making an efficacy claim, repeat a fixed gameplay route from the same save and camera position, keep focus and presentation mode consistent, record power plan and background conditions, exclude a documented warm-up, and run at least three baseline/tuned pairs with alternating order. Report every trial and its exclusions. A separate longer gameplay session is also needed to assess stability beyond these short captures.
