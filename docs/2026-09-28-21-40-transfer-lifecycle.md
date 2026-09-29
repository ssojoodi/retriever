# Transfer lifecycle

## Summary
Close cancellation gaps before extending authentication and workflow verification.

## Product behavior target
Cancelling works even if a server stops reading requests. Closing or quitting during work offers to keep working or cancel; accepted cancellation finishes cleanup then completes the original close/quit automatically.

## Architecture changes
Nonblocking pipe writes with bounded polling, per-descriptor SIGPIPE suppression and cancellation/idle checks. A pending UI completion records the requested close/quit until worker cleanup finishes.

## UX acceptance criteria
No second close or quit required. Keep Working preserves the operation. Busy actions remain disabled until cleanup. A broken pipe reports an error rather than terminating Retriever.

## Automated test plan
Existing Xcode suite plus a protocol fixture that negotiates then stops reading; cancellation and timeout must finish promptly. Verify disconnected writers fail without SIGPIPE termination.

## Manual verification plan
Build and inspect app. UI lifecycle integration checks remain a follow-up until a controllable AppKit harness is available; do not claim core tests prove window behavior.

## Assumptions and non-goals
No authentication or brand changes in this iteration. Full SSH UI verification remains required.

## Verification result
All 16 Xcode core tests passed, including a stalled reader, a stalled writer and a server that closes input. Result: `.build/DerivedData/Logs/Test/Test-Retriever-2026.09.28_21-56-21--0400.xcresult`.

Added `make check-windows` and ran its AppKit runner successfully in the GUI session: active-window menu routing, initial action states, editable field focus, connection-sheet cancellation, minimum-size resize, idle close and controller release. The lifetime test drains its autorelease pool and releases its own window references before checking. This does not yet verify authenticated UI transfers or busy close/quit prompts. Latest inspected built-app screenshot remains `artifacts/verification/browser-window.png`; no new general window layout was introduced.
