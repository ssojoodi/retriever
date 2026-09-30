# Retriever

A minimal native macOS SFTP browser for retrieving remote files. Inspired by Cyberduck.

Requires macOS 14 or later and full Xcode (developed with Xcode 26.6, Swift 6). No third-party dependencies or signing credentials are needed for local development.

```
make build
make test
make check-windows
make check-ssh
make check-browser
make run
```

Xcode is the authoritative build: open `Retriever.xcodeproj`, select the shared `Retriever` scheme, and build. Debug and Release use Swift 6. Outputs stay in `.build/DerivedData` for command-line builds. `make paths` prints the exact app path; `make clean` cleans build products through Xcode.

Open Connection includes a saved-host picker. The most recent successful host is preselected, with its last visited folder. Choose New connection for another host, clear Remote folder to start at home, or Forget to remove an entry. Missing or inaccessible saved folders fall back to the server home folder with a visible notice. No connection is made automatically on launch.

Current workflow: connect with SSH keys, an agent, or an interactive password, browse folders, and download selected regular files. Click a folder’s disclosure arrow to expand or collapse it inline. Contents load on first expansion; Refresh clears expanded folders and reloads the current directory. Double-click folders to open them; use Up to return, Refresh to reload, and Download (⌘D) to choose a local destination. Right-click a file for Download or Preview. Preview retrieves a temporary copy for native Quick Look; closing or replacing the preview removes that copy. Folders and symbolic links cannot be previewed or downloaded. Existing files are preserved: choose a new filename. The status bar reports received bytes during downloads. Cancel disconnects and removes partial output. A server that stops sending or accepting data times out after 30 seconds. Closing or quitting during work offers cancellation and completes after cleanup. New servers show a fingerprint confirmation before connecting. Passwords and key passphrases use a native secure field. Trust decisions are saved by OpenSSH in known_hosts; Retriever does not store passwords. Authentication prompts allow up to five minutes.

The packaged app’s authenticated connection and native-save download were manually verified with a disposable local SFTP server on September 29, 2026. Automated checks also cover exact file bytes and error-state recovery. `make check-windows` requires a logged-in GUI session and verifies initial action states, active-window routing, connection-sheet text focus/cancellation, minimum-size resize, idle close and controller release. It is separate from the core tests.

`Sources/RetrieverApp` contains AppKit UI, `Sources/RetrieverCore` contains testable behavior, and `Tests/RetrieverCoreTests` contains hostless XCTest tests. Plans and evidence notes are tracked under `docs/`; screenshot artifacts are ignored under `artifacts/verification/`. Successful hosts (server, username, port) and their last visited remote folder are saved locally. Passwords are never persisted. Closing the last window quits.

Development is unsigned. Before distribution, copy `Config/LocalSigning.example.xcconfig` to ignored `Config/LocalSigning.xcconfig`, and `release.env.example` to ignored `release.env` using existing Apple Developer credentials. `release.env` uses Make syntax, not shell syntax. Version settings live in `Config/Signing.xcconfig`. `make release` runs the universal Developer ID signing and app/DMG notarization pipeline in an interactive terminal. It validates credentials before building, retains evidence in `.build/release/`, and opens an app copied from the final DMG for manual connect/browse/download/cancel/quit checks before replacing `web-page/Retriever.dmg`. Previous DMGs, checksums, and release metadata are backed up under `docs/dmg-backups/`. Successful releases also write `web-page/Retriever.dmg.sha256` and `web-page/release.json`. The complete branded release pipeline passed for version 0.1.0 build 2 on September 29, 2026, including accepted app/DMG notarization, Gatekeeper assessment and user verification of the app copied from the DMG. A browser-downloaded DMG was also verified. Clean-account quarantine and Intel runtime checks remain unperformed.

No license has been selected.

The SFTP core uses `/usr/bin/ssh`; new hosts require explicit confirmation and changed host keys remain rejected. No remote shell commands are constructed. Core integration tests launch `/usr/libexec/sftp-server` locally against temporary fixtures; they need no network or server credentials. Downloads preserve existing destination files. SSH error sheets include bounded diagnostic details. Interactive authentication uses the app executable as a native SSH askpass helper. Headless core callers retain strict batch mode.

The approved icon artwork is `Brand/Retriever-Logo-Approved.png`; `Brand/RenderIcon.swift` resizes it without changing its composition. Run `make assets` to regenerate all ten macOS icon slots (16 through 1024 pixels). Generated PNGs are tracked, so fresh checkouts build directly in Xcode without first running the renderer.

`make check-ssh` verifies real authenticated SSH transfers and rejection of unknown/changed host keys and unauthorized client keys. It uses installed macOS sshd, Python 3 and disposable test keys on a loopback-only port. It does not alter your SSH configuration. The fixture server and temporary credentials are cleaned up on exit. This transport check is separate from the controller checks and the manually verified packaged-app download.

`make check-browser` runs the production window controller against the same authenticated SSH fixture in a GUI session. It verifies connection fields, listing, folder/Up navigation, native save cancellation, an exact selected-file download to an explicit destination, and disconnect. It captures `artifacts/verification/authenticated-browser-display.png`. Native save-panel confirmation remains a separate manual check: this macOS version does not implement `NSSavePanel.ok(_:)` for automation. The runner is not the packaged app.

`make build-universal` builds unsigned Release into `.build/ReleaseVerification` and verifies Apple silicon and Intel slices in both app and framework. It is not a signed or notarized release. Both architectures compile with a macOS 14 minimum; Intel runtime has not been tested. Current acceptance evidence and unfinished gates are listed in `docs/bootstrap-acceptance.md`.

Use Help → Retriever Help for offline connection, trust, download and cancellation instructions and keyboard shortcuts. The Help panel is reusable and does not interrupt transfers.

For a manual packaged-app test, run `make build`, then `python3 scripts/manual_browser_check.py` in a logged-in macOS session. It prints local connection details and a host fingerprint, then launches the built app with a separate temporary SSH agent. Connect using the printed details, verify the fingerprint, browse the empty folder, and download `retriever-test.txt`. The expected text is `Retrieved successfully with Retriever.` Quit that app instance to stop the server and remove temporary keys. Accepting host trust uses your normal SSH known-hosts file; the fixture does not edit SSH configuration.

`python3 scripts/manual_askpass_check.py` opens two packaged native authentication prompts: enter the displayed dummy value and Continue, then Cancel the second. The runner verifies response bytes and exit status without printing the input. This manual check passed on September 29, 2026.

`python3 scripts/check_askpass_lifetime.py` briefly opens the packaged authentication helper, ends its parent process, and verifies that the helper closes its inherited pipes within a bounded timeout. This check requires a logged-in GUI session but no manual input.

The static Retriever website lives in `web-page/` with its landing page, release notes, approved icon, and social image. Preview with `python3 -m http.server 8105 --bind 127.0.0.1 --directory web-page`, then open http://127.0.0.1:8105. Until a validated release exists, download controls show “Coming soon”. `make release` writes the DMG and manifest that enable those links. Publish the contents of `web-page/` together to your static host; the command does not upload the website. Generated DMGs and release metadata remain ignored. `python3 scripts/check_release_publication.py` verifies local output/backups without Apple credentials.

Release DMGs include a warm Retriever install background, a drag arrow, and a saved Finder layout with the app and Applications shortcut. `Brand/RenderDMGBackground.swift` is the editable background source; `scripts/create_dmg.py` renders it and saves the layout through Finder before signing/notarization. This step requires a logged-in GUI session and permission to automate Finder. Layout staging remains under `.build/release/` for inspection, including after failure.

Website audit: install the isolated test dependency with `npm install --prefix .build/web-audit --no-audit --no-fund playwright`, serve `web-page/` at port 8105 as above, and run `node scripts/check_website.cjs`. It uses an isolated headless Google Chrome instance from `/Applications`, checks desktop/mobile pages and download states, and compares downloaded DMG bytes to release metadata. Screenshots are saved under `artifacts/verification/`.
