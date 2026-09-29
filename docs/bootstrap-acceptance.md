# Bootstrap acceptance audit

Current audit: 2026-09-29. The initial repository and functioning SFTP development app meet the bootstrap criteria. Signed distribution has now passed the local release audit for 0.1.0 build 2; see docs/2026-09-29-00-55-final-release-audit.md for evidence and remaining environment limits.

| Blueprint requirement | Current evidence | Remaining work |
| --- | --- | --- |
| Product contract and iteration history | AGENTS.md, timestamped plans and modular commits | Confirm inferred bundle namespace before distribution |
| Toolchain inspection | Xcode 26.6, Swift 6.3.3, macOS 26.6.2 arm64 recorded in foundation plan | None for local development |
| Independent checkout | Fresh archive of committed source passed `make build` without prior products or signing configuration | None for the verified commit |
| Authoritative Xcode targets and scheme | App, embedded framework and hostless XCTest bundle; plist lint and shared scheme verified | None known |
| Native shell and identity | Running built-app screenshots; icon assets and bundle metadata verified | User confirmed About identity/icon/version, ⌘O/Escape, minimum-size toolbar access and ⌘W quit; Help routing/reuse/close and screenshot verified |
| Actual SFTP workflow | Real authenticated SSH fixture and native controller checks; user confirmed packaged-app connection and text-file download through the native Save dialog on 2026-09-29 | Folder/Up and exact-byte comparison verified by authenticated controller check; user separately confirmed packaged native-save download |
| Trust and credentials | User reached native trust prompt and subsequently completed packaged-app download; prompt construction and scripted encrypted-key tests | Packaged native helper response and cancellation verified with dummy input; parent-exit cleanup verified by bounded process/pipe check; external password server not tested |
| Transfer integrity | 21 core tests, exact bytes, mid-transfer cancellation, destination-race and symlink preservation | External-volume runtime remains untested; local transfer/error and preservation checks passed |
| Window lifecycle | AppKit routing, text focus, sheet cancellation, minimum resize, idle close and release checks | Busy close preservation/cancellation/deferred close and controller release verified; packaged process exited with status 0 and fixture cleanup completed. User additionally confirmed ⌘W closes the main window and quits after closing About |
| Predictable commands | build, test, run, assets, check-windows, check-ssh, check-browser, paths, help, clean | `make release` implements signing, notarization, DMG validation and a manual installed-copy gate; full pipeline verified for build 2 |
| Reproducible brand assets | Native renderer, ten tracked icon slots, deterministic hashes and inspected raster sizes | User confirmed About icon; Finder-specific visual inspection not separately recorded |
| Universal Release build | arm64 and x86_64 verified in app and framework; macOS 14 deployment metadata; version 0.1.0 build 1 | Intel runtime not tested |
| Direct distribution | Signing config examples and version source tracked | Signed/notarized build 2, Gatekeeper, mounted-copy user test and browser download verified; clean-account quarantine and Intel runtime remain untested |
| Final handoff | README and AGENTS track commands and limitations | Final audit recorded in docs/2026-09-29-00-10-bootstrap-handoff.md; unrelated untracked logo/website work preserved |

Do not treat the controller harness as the packaged executable. Do not treat scripted askpass replies as user interaction with the native helper. Keep core tests, GUI checks and release validation separate.
