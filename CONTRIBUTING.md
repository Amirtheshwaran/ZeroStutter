# Contributing

ZeroStutter is a Windows frame-pacing toolkit. Keep every tuning control explicit, reversible, and measurable. The monitor remains read-only unless the user opts in.

## Before submitting

- Run the validation script in each shell you have installed:
  - `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Validate-Project.ps1`
  - `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Validate-Project.ps1`
- Keep profile entries observation-only unless you have a measured reason and document how to test the setting safely.
- Use documented Windows APIs, actual CPU topology, and snapshots saved before mutation. Preserve different settings chosen outside ZeroStutter. Test normal shutdown, partial failure, stale PID identity, and owner-crash recovery.
- Do not add memory purges, undocumented timer tweaks, guessed CPU masks, automatic antivirus exclusions, or edits to the user's original power plan.
- Do not claim FPS, latency, or stability improvements without reproducible measurements and the full test setup.
- Keep the monitor usable without administrator rights or third-party PowerShell modules.
- Run real process tests only on disposable children. Mock global power mutations in the routine suite. Clearly separate fixture correctness from measured game performance.
- Preserve the MIT license in portable and installed distributions. Attribute any new third-party code and check its redistribution terms.

## Adding a profile

Add a unique executable name to `profiles.json`. Use `Observe` by default. The JSON schema is `schema/profiles.schema.json`. Process names may differ from the executable filename; confirm the actual Windows process name before adding a profile.
