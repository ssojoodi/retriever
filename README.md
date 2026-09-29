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

Current workflow: connect with SSH keys, an agent, or an interactive password, browse folders, and download selected regular files. Double-click folders to open them; use Up to return, Refresh to reload, and Download (⌘D) to choose a local destination. Existing files are preserved: choose a new filename. The status bar reports received bytes during downloads. Cancel disconnects and removes partial output. A server that stops sending or accepting data times out after 30 seconds. Closing or quitting during work offers cancellation and completes after cleanup. New servers show a fingerprint confirmation before connecting. Passwords and key passphrases use a native secure field. Trust decisions are saved by OpenSSH in known_hosts; Retriever does not store passwords. Authentication prompts allow up to five minutes.

The native browser is wired to the tested SFTP core; authenticated SSH through the UI still needs end-to-end verification. Authenticated workflow checks remain pending. `make check-windows` requires a logged-in GUI session and verifies initial action states, active-window routing, connection-sheet text focus/cancellation, minimum-size resize, idle close and controller release. It is separate from the core tests.

`Sources/RetrieverApp` contains AppKit UI, `Sources/RetrieverCore` contains testable behavior, and `Tests/RetrieverCoreTests` contains hostless XCTest tests. Plans and evidence notes are tracked under `docs/`; screenshot artifacts are ignored under `artifacts/verification/`. No connection history or passwords are persisted by Retriever. Closing the last window quits.

Development is unsigned. Before distribution, copy `Config/LocalSigning.example.xcconfig` to ignored `Config/LocalSigning.xcconfig`, and `release.env.example` to ignored `release.env` using existing Apple Developer credentials. `release.env` uses Make syntax, not shell syntax. Version settings live in `Config/Signing.xcconfig`. The signed, notarized universal DMG pipeline is a separate milestone; `make release` currently fails explicitly.

No license has been selected.

The SFTP core uses `/usr/bin/ssh`; new hosts require explicit confirmation and changed host keys remain rejected. No remote shell commands are constructed. Core integration tests launch `/usr/libexec/sftp-server` locally against temporary fixtures; they need no network or server credentials. Downloads preserve existing destination files. SSH error sheets include bounded diagnostic details. Interactive authentication uses the app executable as a native SSH askpass helper. Headless core callers retain strict batch mode.

Icon artwork is editable in `Brand/RenderIcon.swift`. Run `make assets` to regenerate all ten macOS icon slots (16 through 1024 pixels). Generated PNGs are tracked, so fresh checkouts build directly in Xcode without first running the renderer.

`make check-ssh` verifies real authenticated SSH transfers and rejection of unknown/changed host keys and unauthorized client keys. It uses installed macOS sshd, Python 3 and disposable test keys on a loopback-only port. It does not alter your SSH configuration. The fixture server and temporary credentials are cleaned up on exit. This transport check is separate from authenticated GUI verification.

`make check-browser` runs the production window controller against the same authenticated SSH fixture in a GUI session. It verifies connection fields, listing, folder/Up navigation, native save cancellation, an exact selected-file download to an explicit destination, and disconnect. It captures `artifacts/verification/authenticated-browser-display.png`. Native save-panel confirmation remains a separate manual check: this macOS version does not implement `NSSavePanel.ok(_:)` for automation. The runner is not the packaged app.

`make build-universal` builds unsigned Release into `.build/ReleaseVerification` and verifies Apple silicon and Intel slices in both app and framework. It is not a signed or notarized release. Both architectures compile with a macOS 14 minimum; Intel runtime has not been tested. Current acceptance evidence and unfinished gates are listed in `docs/bootstrap-acceptance.md`.

Use Help → Retriever Help for offline connection, trust, download and cancellation instructions and keyboard shortcuts. The Help panel is reusable and does not interrupt transfers.
