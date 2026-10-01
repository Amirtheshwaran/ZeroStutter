# Contributing

Thanks for considering a contribution. Keep behavior conservative and documented. ZeroStutter should remain read-only unless a user explicitly opts into a change.

## Before submitting

- Run `pwsh -NoProfile -File .\tests\Validate-Project.ps1`.
- Keep profile entries observation-only unless you have a measured reason and document how to test the setting safely.
- Do not add memory purges, undocumented timer tweaks, guessed CPU masks, or persistent power-plan changes.
- Do not claim FPS, latency, or stability improvements without reproducible measurements and the full test setup.
- Keep the monitor usable without administrator rights or third-party PowerShell modules.

## Adding a profile

Add a unique executable name to `profiles.json`. Use `Observe` by default. The JSON schema is `schema/profiles.schema.json`. Process names may differ from the executable filename; confirm the actual Windows process name before adding a profile.
