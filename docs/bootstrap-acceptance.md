# Bootstrap acceptance audit

Current audit: 2026-09-29. This file records evidence and open gates; it is not a completion declaration.

| Blueprint requirement | Current evidence | Remaining work |
| --- | --- | --- |
| Product contract and iteration history | AGENTS.md, timestamped plans and modular commits | Confirm inferred bundle namespace before distribution |
| Toolchain inspection | Xcode 26.6, Swift 6.3.3, macOS 26.6.2 arm64 recorded in foundation plan | None for local development |
| Independent checkout | Fresh archive of committed source passed `make build` without prior products or signing configuration | None for the verified commit |
| Authoritative Xcode targets and scheme | App, embedded framework and hostless XCTest bundle; plist lint and shared scheme verified | None known |
| Native shell and identity | Running built-app screenshots; icon assets and bundle metadata verified | About panel visual check and remaining keyboard/overflow checks; Help routing/reuse/close and screenshot verified |
| Actual SFTP workflow | Real authenticated SSH fixture and native controller checks; user confirmed packaged-app connection and text-file download through the native Save dialog on 2026-09-29 | Explicit manual folder/Up confirmation and saved-content comparison not separately reported |
| Trust and credentials | User reached native trust prompt and subsequently completed packaged-app download; prompt construction and scripted encrypted-key tests | Native password/passphrase response/cancellation/lifetime integration; external password server not tested |
| Transfer integrity | 21 core tests, exact bytes, mid-transfer cancellation, destination-race and symlink preservation | External-volume runtime coverage; more transfer/error UX checks |
| Window lifecycle | AppKit routing, text focus, sheet cancellation, minimum resize, idle close and release checks | Busy close preservation/cancellation/deferred close and controller release verified; packaged process exited with status 0 and fixture cleanup completed. Close-button versus menu-quit path not separately reported |
| Predictable commands | build, test, run, assets, check-windows, check-ssh, check-browser, paths, help, clean | `make release` implements signing, notarization, DMG validation and a manual installed-copy gate; credential preflight checked, full pipeline unverified |
| Reproducible brand assets | Native renderer, ten tracked icon slots, deterministic hashes and inspected raster sizes | Finder/About visual checks |
| Universal Release build | arm64 and x86_64 verified in app and framework; macOS 14 deployment metadata; version 0.1.0 build 1 | Intel runtime not tested |
| Direct distribution | Signing config examples and version source tracked | Verified identity/profile, signing and notarized DMG pipeline, Gatekeeper and installed DMG checks; separate release milestone |
| Final handoff | README and AGENTS track commands and limitations | Final full audit, clean tree, exact final app/screenshot evidence after remaining work |

Do not treat the controller harness as the packaged executable. Do not treat scripted askpass replies as user interaction with the native helper. Keep core tests, GUI checks and release validation separate.
