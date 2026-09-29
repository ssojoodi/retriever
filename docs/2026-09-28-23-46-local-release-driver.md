# Local release driver

## Summary
Replace the release placeholder with the explicit Developer ID and notarized-DMG sequence from the blueprint.

## Product behavior target
`make release` validates supplied existing credentials, builds a universal Release app, signs nested code first, notarizes/staples the app, creates and notarizes/staples the DMG, then validates and publishes locally. No website upload.

## Architecture changes
Python subprocess driver with argument arrays, unique staging under .build/release, explicit gates and retained logs. A validated DMG is copied atomically into dist with a backup of the prior artifact. Configuration remains in ignored release.env.

## UX acceptance criteria
Missing or placeholder credentials fail before building or modifying an existing artifact. Failed signing/notarization never replaces the last good DMG. No passwords or private keys in code/logs.

## Automated test plan
Compile the script and exercise missing/placeholder configuration failures. Check installed notarytool syntax. Full signing/notarization cannot be claimed without verified credentials.

## Manual verification plan
Mounted DMG validates the included app and Applications link. The driver copies the app out, detaches the image, launches that copy, and requires interactive confirmation of connect/browse/download/cancel/quit before replacing the stable artifact; clean-machine download/install remains a release acceptance gate when credentials are available.

## Assumptions and non-goals
No identity/profile has been verified. User must finish cmux Computer Use onboarding before packaged GUI acceptance can proceed; native app-control tool reported onboarding incomplete on this iteration. Release driver implementation does not establish release readiness.

## Results
Python syntax and valid/invalid credential validation passed. `make release` with unset credentials failed before staging/building as expected. `git diff --check` passed. Installed notarytool submit/log usage was inspected. Signing, notarization, mounted-copy runtime and quarantine acceptance remain unverified.
