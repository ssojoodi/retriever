# Authenticated window workflow

## Summary
Exercise the native controller against the authenticated loopback fixture.

## Product behavior target
A connection sheet starts real SSH authentication, the table displays remote files, folder actions navigate, and the native download panel retrieves exact bytes.

## Architecture changes
Controller accepts a browser instance; normal construction is unchanged. Core has an internal test-only session factory and initial path so the test runner can isolate SSH keys/known_hosts without changing personal settings. The fixture driver gains a GUI-check mode compiling the actual app controller sources.

## UX acceptance criteria
Connection fields feed the worker correctly. Directory table and action states reflect server results. Save-panel cancellation does nothing; confirmed download retrieves exact bytes and reports completion. Disconnect resets the browser.

## Automated test plan
Run the authenticated GUI fixture in a logged-in session: connection, listing, empty folder, Up, save-panel cancellation, download and disconnect. Capture the connected controller view for visual inspection. Keep existing core and SSH checks separate.

## Manual verification plan
Inspect connected table evidence. The runner uses production controller sources and framework but is not the packaged application. Native helper interaction and packaged app acceptance remain distinct checks.

## Assumptions and non-goals
No external credentials; no modification of personal SSH configuration. No Accessibility automation permission is required to exercise controls owned by the test process.

## Evidence and limits
- `make check-browser` passed, including its unsigned Debug build. Authenticated native connection fields, file table, empty folder navigation, Up, save cancellation, exact 131,328-byte selected-file download to an explicit destination, and disconnect all passed.
- Native save confirmation could not be automated: `NSSavePanel.ok(_:)` raised “not implemented”; a synthetic Return event also failed to complete the panel. The final runner cancels the actual panel and calls the shared `retrieveSelection(to:)` operation with a test destination. It must not be described as confirming a save panel end to end.
- Inspected `artifacts/verification/authenticated-browser-display.png`: connected title, remote path, folder/file rows, sizes, modified dates, toolbar states and item count render clearly. It shows BrowserChecks running production controller sources, not the packaged Retriever executable. The cached content-only PNG loses some layer-backed labels; use the display screenshot as visual evidence.
- Fixture server and credentials cleaned up after each run. Full packaged-app flow, native prompt responses and native save confirmation remain pending.
