# Final website and release audit

## Summary
Run the complete branded release and audit the local publishing folder.

## Product behavior target
A signed, notarized branded DMG and accurate static website, with verified download bytes/checksum, backups and install behavior.

## Architecture changes
Increment build number to 2 to distinguish the final installer. Fix only issues found during audit.

## UX acceptance criteria
Desktop/mobile website layout, links, release availability, actual download and release notes agree with the artifact. Installed app is tested before replacing the website DMG.

## Automated test plan
Run release validation and website checks; verify downloaded bytes against metadata and signatures; inspect backups.

## Manual verification plan
Inspect website rendering where browser access permits. User handles native app checks with Computer Use disabled. Record unavailable clean-machine/Intel checks accurately.

## Assumptions and non-goals
Prepare local web-page for publication. No website upload is requested. Keep credentials out of tracked files and logs.

## Results
- Version 0.1.0 build 2: universal Release built, nested code/app signed, app and DMG notarization Accepted, both tickets stapled/validated, Gatekeeper accepted, hdiutil verified. Evidence: .build/release/run-ldmap8ba.
- Initial full run exposed a Finder container-window reference failure. Changed layout automation to retain the newly created Finder window explicitly; the complete subsequent release passed.
- Signed app copied out of the final DMG and opened. User tested against a disposable loopback server and confirmed “it's all good! VERIFIED”. The release's installed-copy gate then completed.
- Final web-page/Retriever.dmg is 2,558,607 bytes. SHA-256: bcfe3535f687c1016fa7b35e4fe464ad8f6879ba00ef80eec351ee78a791c40a. Manifest and checksum sidecar match. Prior build 1 digest e824d17ff872f499ca38143944041319cca7eef1d53117ce0c4abceef3482429 verified in docs/dmg-backups.
- Browser runtime had no available browser. Used isolated headless Chrome with a temporary Playwright installation; no personal browser profile or Computer Use settings changed.
- Desktop (1440px) and mobile (390px) landing/release-note pages passed; screenshots visually inspected. No horizontal overflow or page errors. Navigation, keyboard skip link, download-button click, fallback when metadata is missing, and HTTP download checksum passed. Final browser-downloaded build 2 also passed stapler validation and Gatekeeper assessment.
- Raised muted text contrast and removed stale pre-release wording from installation steps. Publication-helper regression passed; git diff --check passed.
- No public website upload performed. Clean-account/other-Mac quarantine testing, Intel runtime and external password-server compatibility remain untested. Local publishing folder is ready for upload with release.json, Retriever.dmg and checksum kept together.
