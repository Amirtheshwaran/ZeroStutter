## Problem and change

Describe the problem, the behavior changed, and any linked issue.

## Verification

List the commands run and their results. State which PowerShell versions and Windows environment were used, or explain checks that remain for CI or hardware testing.

For a performance claim, link the repeated baseline/tuned measurements, settings, metric definitions, and unchanged or worse results.

## Restoration and limitations

For tuning changes, explain how original state is saved, restored, and preserved when another application changes it. Describe failure paths exercised and remaining limitations. Mark this section not applicable for changes that do not affect tuning.

## Review checklist

- [ ] The change is focused and user-facing behavior is documented.
- [ ] Relevant regression coverage is included, or the reason it is unnecessary is explained.
- [ ] No game files, captures with personal data, generated packages, or third-party binaries are committed.
- [ ] New third-party source is attributed and its license is compatible.
- [ ] Performance statements match the available evidence.
