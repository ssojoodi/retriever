# Connection error details

## Summary
Preserve useful SSH diagnostics instead of discarding stderr and reporting every failure as a generic disconnect.

## Product behavior target
Connection failures explain host verification, rejected credentials or unreachable servers using the SSH client's actual message. Messages remain transient, bounded and plain text.

## Architecture changes
A nonblocking stderr pipe is drained alongside protocol input/output on the existing worker. Retain at most 16 KiB; continue draining excess output so SSH cannot deadlock on a full diagnostics pipe. Bound each drain pass so cancellation is still checked.

## UX acceptance criteria
Existing error sheets show useful details. No credentials are collected or persisted. Control characters cannot alter displayed text. Cancellation and timeout keep their existing meanings.

## Automated test plan
Simulated SSH authentication failure, control-character filtering and stderr exceeding pipe capacity. Existing transfer and cancellation tests must still pass.

## Manual verification plan
No layout change. Real authenticated SSH UI workflow and interactive authentication remain pending.

## Assumptions and non-goals
This improves failure reporting; it does not implement password or first-use trust prompts. No security checks are relaxed.

## Verification evidence
Unsigned Debug build and all 18 XCTest cases passed. New fixtures verify rejected authentication diagnostics, control-character filtering and more than 180 KiB of stderr without pipe deadlock, while retaining no more than 16 KiB. Result: `.build/DerivedData/Logs/Test/Test-Retriever-2026.09.28_22-29-47--0400.xcresult`. Existing cancellation, timeout, real local SFTP downloads and destination preservation tests remain green. No UI layout changed or new GUI verification claimed.
