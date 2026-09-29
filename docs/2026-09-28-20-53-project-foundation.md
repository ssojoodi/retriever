# Project foundation

## Summary
Establish an independent native Retriever repository following mac-app-blueprint.md. This iteration creates the buildable shell and validated connection input; subsequent iterations implement SFTP and verification of the entire retrieval workflow.

## Product behavior target
A minimal single-window remote file browser. The first complete usable slice connects using SFTP, browses directories and retrieves files. Foundation alone is not completion of that slice.

## Architecture changes
Three Xcode targets: Retriever, embedded RetrieverCore, hostless RetrieverCoreTests. Swift 6, macOS 14, system appearance. Personal bundle namespace ca.sahand; unsigned local builds. Core validates connection inputs. UI uses native menus, table and connection sheet. No external dependencies initially; investigate reliable SFTP transport in the next iteration.

## UX acceptance criteria
One retained window, native keyboard editing, connect action, readable empty state, minimal toolbar, correct About identity and app icon. Invalid host, user or port receives a visible error. No pretend successful connections.

## Automated test plan
Validate pbxproj, list shared scheme, inspect effective settings, unsigned build and XCTest. Test input validation boundaries. Later AppKit checks cover window lifetime and routing.

## Manual verification plan
Launch exact built app, inspect screenshot, exercise connection sheet cancellation, input errors, keyboard editing, minimum size and About. Record unperformed checks honestly.

## Assumptions and non-goals
SFTP first; FTP, uploads and destructive remote actions excluded initially. No credentials visible in initial identity inspection, so notarized distribution is separate. No persistent credentials or connection history initially. Universal release intended but unverified until release build. No license selected. User authorized modular commits.

## Foundation milestone evidence
- Xcode 26.6 / Swift 6.3.3 / macOS 26.6.2 arm64 inspected; zero visible signing identities.
- `plutil -lint` passed; shared Retriever scheme discovered.
- Unsigned Xcode Debug test command passed: 5 tests, zero failures. Result: `.build/DerivedData/Logs/Test/Test-Retriever-2026.09.28_21-10-44--0400.xcresult`.
- Effective settings verified: Swift 6, macOS 14, ca.sahand.Retriever, version 0.1.0 build 1.
- Exact `.build/DerivedData/Build/Products/Debug/Retriever.app` launched. `artifacts/verification/foundation.png` inspected: native titled window, connection action, empty state and status render correctly. Symbol is too small and needs adjustment.
- Not yet verified: connection-sheet interaction, About, minimum size, controller lifetime, cancellation. Icon and SFTP workflow remain incomplete. This is a build-foundation milestone, not completed bootstrap acceptance.
