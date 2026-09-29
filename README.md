# Retriever

A minimal native macOS SFTP browser for retrieving remote files. Inspired by Cyberduck.

Requires macOS 14 or later and full Xcode (developed with Xcode 26.6, Swift 6). No third-party dependencies or signing credentials are needed for local development.

```
make build
make test
make run
```

Xcode is the authoritative build: open `Retriever.xcodeproj`, select the shared `Retriever` scheme, and build. Debug and Release use Swift 6. Outputs stay in `.build/DerivedData` for command-line builds. `make paths` prints the exact app path; `make clean` cleans build products through Xcode.

Current workflow: connect with existing SSH keys/agent to a host already trusted in your SSH known-hosts file, browse folders, and download selected regular files. Double-click folders to open them; use Up to return, Refresh to reload, and Download (⌘D) to choose a local destination. Existing files are preserved: choose a new filename. Cancel disconnects and removes partial output. A server that stops sending data times out after 30 seconds. Password and first-use host trust prompts are not implemented yet.

The native browser is wired to the tested SFTP core; authenticated SSH through the UI still needs end-to-end verification. App icon assets and AppKit integration checks remain pending.

`Sources/RetrieverApp` contains AppKit UI, `Sources/RetrieverCore` contains testable behavior, and `Tests/RetrieverCoreTests` contains hostless XCTest tests. Plans and evidence notes are tracked under `docs/`; screenshot artifacts are ignored under `artifacts/verification/`. No connection details or credentials are persisted. Closing the last window quits.

Development is unsigned. Before distribution, copy `Config/LocalSigning.example.xcconfig` to ignored `Config/LocalSigning.xcconfig`, and `release.env.example` to ignored `release.env` using existing Apple Developer credentials. `release.env` uses Make syntax, not shell syntax. Version settings live in `Config/Signing.xcconfig`. The signed, notarized universal DMG pipeline is a separate milestone; `make release` currently fails explicitly.

No license has been selected.

The SFTP core uses `/usr/bin/ssh` with existing keys/agent and strict known-host verification. No remote shell commands are constructed. Core integration tests launch `/usr/libexec/sftp-server` locally against temporary fixtures; they need no network or server credentials. Downloads preserve existing destination files. Interactive authentication and detailed SSH error diagnostics remain pending.
