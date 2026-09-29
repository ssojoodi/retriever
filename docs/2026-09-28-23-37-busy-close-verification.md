# Busy close verification

## Summary
Exercise the real close-confirmation path while the worker is waiting on a stalled protocol process.

## Product behavior target
Keep Working leaves the operation and window alive. Cancel and Close interrupts the worker, waits for cleanup, then closes automatically without a second user action.

## Architecture changes
No new production abstraction. Use the existing internal browser factory with a controlled stalled subprocess and interact with the controller's own native alerts in the AppKit runner.

## UX acceptance criteria
The safe choice preserves work. Accepted cancellation closes only after busy state is cleared. A closed controller can be released.

## Automated test plan
Connect through the real sheet into the stalled fixture; choose Keep Working, then close again and choose Cancel and Close. Assert busy/visible states and eventual close. Retain existing AppKit checks.

## Manual verification plan
Capture the busy close confirmation in the native harness and inspect it. Full packaged-app quit remains a separate acceptance check.

## Assumptions and non-goals
The stalled process exercises UI and worker cancellation; prior core tests establish removal of partial downloads. No need for external servers or credentials.

## Evidence
`make check-windows` passed with production lifecycle code unchanged. The stalled connection remains busy and visible after Keep Working; Cancel and Close clears busy state, closes automatically and releases the controller. The first lifetime assertion retained an autoreleased controller constructed outside the test pool; constructing it inside the pool corrected the test. Speculative production ownership changes were reverted. The active-window check now explicitly makes its window key immediately before routing a menu action.

Inspected `artifacts/verification/busy-close.png`: Keep Working is the default; Cancel and Close and cleanup explanation are readable. This is the native harness. Full packaged-app quit and save confirmation are still separate open gates.
