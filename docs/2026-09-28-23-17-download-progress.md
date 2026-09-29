# Download progress

## Summary
Show retrieved byte counts and test cancellation after download data has already been written.

## Product behavior target
The status bar updates while a file downloads. Cancel removes its partial output and never publishes an incomplete destination. Delayed progress callbacks cannot overwrite a completed or newer operation's status.

## Architecture changes
Session reports cumulative bytes after successful writes. Browser throttles reporting to ten updates per second and delivers a final count. UI updates on the main actor and matches the active cancellation token before accepting progress.

## UX acceptance criteria
Readable downloaded byte count, responsive Cancel, no success message before publication, no partial output left after cancellation.

## Automated test plan
Verify monotonic progress and exact final count against a local SFTP server. Cancel from the first received chunk; confirm destination absent and no partial file left. Existing 18 tests must pass.

## Manual verification plan
Status formatting is a small change; connected UI progress remains part of the pending authenticated GUI workflow check. Do not infer GUI correctness solely from core tests.

## Assumptions and non-goals
No speed estimate, recursive downloads or transfer queue. Remote advertised sizes may change, so display actual retrieved bytes without promising a percentage.

## Verification evidence
Unsigned Debug build and all 19 XCTest cases passed. The new real local SFTP test verifies monotonically increasing counts, exact final byte count and payload, then cancels after a chunk is written and verifies no destination or partial file remains. Result: `.build/DerivedData/Logs/Test/Test-Retriever-2026.09.28_23-20-36--0400.xcresult`. Authenticated GUI progress has not yet been visually exercised; it remains in the end-to-end acceptance work.
