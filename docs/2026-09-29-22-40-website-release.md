# Website release preparation

Update release notes and landing-page copy for saved hosts and last folders, inline folder expansion, right-click Download and Quick Look Preview, and the rounded app icon. Preserve prior release notes. Match the next version/build with the CLI release configuration. Keep download buttons unavailable while the existing manifest describes an older release. Do not generate or replace the DMG, checksum, or release manifest; the user will run the release CLI.

Validate desktop/mobile layouts, links, release gating for old/missing/current manifests, and the existing local artifact checksum. Record simulated metadata explicitly in test output.

## Version and handoff
User selected 0.2.0 (build 3). Updated `Config/Signing.xcconfig` and both pages’ expected release version/build. The normal `make release` command creates the signed/notarized DMG, checksum, and matching `release.json` after its installed-copy verification. Publish all of `web-page/` together after that succeeds. No DMG, checksum, or manifest was modified for this preparation.

## Verification
Browser audit passed for desktop and mobile layouts, navigation, skip link, downloaded artifact checksum, and old/missing/current release metadata states. Read and inspected `website-desktop.png` and `release-notes-mobile.png` in `artifacts/verification/`. These screenshots simulate the future matching manifest to verify the available state; they are not evidence that 0.2.0 has been signed or notarized. The current local artifact remains version 0.1.0 (build 2).
