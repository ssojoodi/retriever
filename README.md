# Retriever

**A native Mac app for moving files between your Mac and your servers.**

Retriever started with a simple need: grab a few files from a server without using the command line. Written in Swift and AppKit, it provides SFTP browsing, previews, uploads, downloads, and an embedded SSH terminal.

[Download for Mac](https://sojoodi.com/apps/Retriever/) · [Release notes](https://sojoodi.com/apps/Retriever/release-notes.html) · [Source code](https://github.com/ssojoodi/retriever)

![Retriever browsing remote folders](web-page/screenshots/0.2.0/expanded-folders.png)

## Use Retriever

Requires an **Apple silicon Mac with macOS 14 or later** and an SFTP server.

- Connect with SSH keys, an SSH agent, or a password. Successful connections remember the host and last folder; passwords are never saved.
- Expand folders in the file tree and navigate with arrow keys.
- Press **Space** to preview a file and **Escape** to close or cancel the preview. Large files require confirmation.
- Download with the native Save dialog, or press **⌘U** to upload one file to the current folder. Transfers support cancellation and explicit replacement approval.
- Open **Downloads (⇧⌘J)** to find previous downloads in Finder or clear the history without deleting files.
- Right-click **SSH into Folder** to open a dark terminal at that folder, or at a selected file’s parent. **Files / Terminal** switches views without ending SSH; **End Session** closes it.

Retriever asks you to verify new server fingerprints and rejects changed host keys. SSH terminal access requires a POSIX-compatible server shell. FTP, folder transfers, and symbolic-link transfers are not supported.

## Build and run

Install full **Xcode with Swift 6** and Apple’s Metal toolchain. Development builds need no signing credentials.

```sh
git clone https://github.com/ssojoodi/retriever.git
cd retriever
open Retriever.xcodeproj
```

Select the **Retriever** scheme and build once. Approve `SwiftTermBuildInfoPlugin` when Xcode prompts; approval applies to that package revision. If the Metal toolchain is missing, install it with `xcodebuild -downloadComponent MetalToolchain`.

```sh
make run             # Build and open the app
make build-release   # Build and verify an optimized arm64 app
make paths           # Show output locations
```

Xcode is the source of truth; add new Swift files to their targets. Build output stays in `.build/`.

## Architecture

| Component | Responsibility |
| --- | --- |
| [RetrieverApp](Sources/RetrieverApp) | AppKit interface, Quick Look previews, native authentication prompts, and the embedded SwiftTerm view. |
| [RetrieverCore](Sources/RetrieverCore) | SFTP protocol, transfers, cancellation, and connection/download history. |
| [Tests](Tests) | Core tests and native UI/SSH checks with disposable local servers. |

`SFTPBrowser` owns `SFTPSession` on a dedicated worker. The session speaks SFTP v3 through the system SSH client, keeping network I/O off the main thread. Transfers use temporary files and publish after completion; replacement requires approval. The terminal uses a separate SSH process, so switching views does not interrupt SFTP.

The website is in [web-page](web-page), artwork in [Brand](Brand), and version settings in [Config/Signing.xcconfig](Config/Signing.xcconfig).

## Test

```sh
make test            # Core XCTest suite
make check-ssh       # SSH transport and authentication
make check-browser   # Browsing, previews, downloads, and uploads
make check-terminal  # Embedded terminal and SSH lifecycle
make check-windows   # Window behavior and lifecycle
```

Integration checks require Python 3; UI checks need a logged-in macOS GUI session. Fixtures use temporary SSH keys. For manual testing, run `python3 scripts/manual_browser_check.py --shell`; it prints connection details and stops when the opened app quits.

## Release

Copy `release.env.example` to the ignored `release.env`. Set your Developer ID signing identity and notarization Keychain profile, then run:

```sh
make release
```

The script builds, signs, notarizes, and validates the DMG. It replaces the local website download and metadata in `web-page/`, backing up old artifacts in `docs/dmg-backups/`. Matching dSYM files remain in the release evidence folder for crash reports. Upload the website separately.

Versions advance **0.1.0 → 0.2.0 → 0.3.0** until 1.0.0, with no separate build counter.

## License

[MIT](LICENSE) · Copyright © 2026 Sahand Sojoodi. Dependency licenses are in [ThirdPartyNotices.txt](ThirdPartyNotices.txt).
