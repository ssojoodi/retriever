# Native authentication helper check

## Summary
Verify the packaged native helper with manual input after the packaged SFTP download succeeded.

## Product behavior target
A secure field returns the supplied dummy passphrase to its parent; Cancel returns failure and no credential bytes.

## Architecture changes
No product changes. A small manual runner invokes the actual app executable in askpass mode and compares captured output without logging it.

## UX acceptance criteria
User enters retriever-test in the first prompt and cancels the second. Both native dialogs exit normally with the expected response.

## Automated test plan
Compile Python source and assert exact helper bytes/exit status after user interaction. Five-minute timeout bounds each prompt.

## Manual verification plan
Inspect secure field and activate Continue then Cancel in separate dialogs. User keeps Computer Use disabled.

## Assumptions and non-goals
Dummy text only; no server, real credentials, or password persistence. This check does not establish an external password server or parent-exit cleanup.

## Results
The user completed both native dialogs. The runner exited 0 after verifying the exact dummy response with exit 0 and empty output on cancellation with exit 1. No credential text was printed.
