# Authentication helper lifetime

## Summary
Verify the packaged native authentication helper closes after its parent exits.

## Product behavior target
Cancelling a connection must not leave an orphan authentication dialog.

## Architecture changes
Add a process-level check that launches the exact built helper through an intermediate parent. No production changes.

## UX acceptance criteria
The helper remains active before parent exit, then closes automatically without user input.

## Automated test plan
Require the intermediate parent to observe a live helper after two seconds. Exit that parent and require EOF on inherited output pipes within eight seconds overall. On timeout terminate the isolated test process group.

## Manual verification plan
No interaction required; a brief test dialog appears. Final About/keyboard/minimum-window checks requested separately from the user.

## Assumptions and non-goals
This checks the parent-exit cleanup mechanism, not external password-server compatibility or signed distribution.

## Results
The packaged helper was alive when the parent exited and released its inherited pipes within the timeout. Runner exited 0. No app changes needed.
