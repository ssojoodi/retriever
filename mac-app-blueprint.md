# Native Mac app blueprint

Use this document as the first file in a new app repository. It is an implementation brief for the agent building that app. Read it fully before creating files. Adapt the product details; preserve the repeatable build, test, verification, and release practices.

This blueprint comes from inspecting Capture at `/Users/sahand/src/tries/2026-06-26-skitch-equivalent` on September 28, 2026. The reference app uses Swift, AppKit, an embedded core framework, XCTest, a shared Xcode scheme, and a scripted Developer ID DMG release. Treat that repository as a read-only reference. The new app must build independently of it.

## 1. Establish the app contract

Start from the user's product request. Record these decisions in `AGENTS.md` and the first iteration plan:

| Decision | Starting point |
| --- | --- |
| User-facing name | Use the name supplied by the user. |
| Internal identifier | A Swift-safe name without spaces, such as `MyApp`. |
| Primary workflow | One sentence describing the task the app completes. |
| First usable slice | The smallest end-to-end version of that workflow. |
| Bundle identifier | A new, stable reverse-DNS identifier under the developer's chosen namespace. |
| Framework and test identifiers | Distinct identifiers derived from the app identifier. |
| Platform | Native macOS, Swift and AppKit. |
| Minimum macOS | Start with Capture's macOS 14.0 baseline unless required APIs or audience justify another choice. |
| Appearance | Capture uses a light appearance; choose deliberately for this app. |
| Window model | Choose single window, multiple independent windows, or document-based behavior. |
| Persistence | Specify what is saved, where it is saved, and what happens on close. |
| Distribution | Default to direct distribution using Developer ID and a notarized DMG. |
| Supported processors | State whether the release supports Apple silicon only or Apple silicon and Intel. |
| Non-goals | Explicitly exclude features outside the initial workflow. |

Infer routine choices from the request. Ask only about missing decisions that block useful work. Do not copy Capture's annotation tools, image formats, branding, bundle IDs, or screenshot-related restrictions into unrelated products.

Use `MyApp`, `MyAppCore`, and `MyAppCoreTests` as placeholders throughout this document. Replace them consistently. Keep a separate display name if the product name contains spaces. Do not ship `com.local.Capture` or a placeholder identifier.

## 2. Inspect this Mac before installing anything

Run these read-only checks from the new repository:

```bash
pwd
git status --short
xcode-select -p
xcrun xcodebuild -version
xcrun swift --version
sw_vers
uname -m
xcrun --find notarytool
xcrun --find stapler
security find-identity -v -p codesigning
```

The inspected machine selected `/Applications/Xcode.app/Contents/Developer` and reported Swift 6.3.3 on arm64. Recheck rather than pinning those observed values. Use full Xcode; Command Line Tools alone are insufficient for this workflow. Do not install a second toolchain or change the global Xcode selection when the existing setup works. If needed, use a command-scoped `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

Use the existing Apple Developer account, team, certificates, and Keychain credentials. Do not create a new developer account or certificate just because this is a new repository. Team identity can be shared; bundle identifiers must be app-specific.

The inspection session returned `0 valid identities found`. This does not prove the developer has no certificates: access can depend on the session and unlocked Keychain. No actual Team ID, signing identity, or working notarization profile was verified. Never invent these values. Continue unsigned development while resolving release access when needed.

## 3. Create a small, self-contained repository

Create the following structure. Add optional directories only when their purpose exists.

```text
mac-app-blueprint.md
AGENTS.md
README.md
.gitignore
Makefile
MyApp.xcodeproj/
  project.pbxproj
  xcshareddata/xcschemes/MyApp.xcscheme
Config/
  Signing.xcconfig
  LocalSigning.example.xcconfig
Sources/
  MyAppApp/
    main.swift
    AppDelegate.swift
    AppMenu.swift
    MainWindowController.swift
    Assets.xcassets/
      Contents.json
      AppIcon.appiconset/Contents.json
  MyAppCore/
    AppState.swift
Tests/
  MyAppCoreTests/
    AppStateTests.swift
  MyAppAppChecks/                 # Only when needed for AppKit integration checks.
scripts/
  check_windows.sh               # If a standalone AppKit check runner is used.
  create_dmg.sh                  # Add before the first distributable release.
Brand/                          # Editable brand sources and asset generators.
docs/
  YYYY-MM-DD-HH-MM-project-foundation.md
release.env.example
```

Generated products belong under `.build/`; visual evidence belongs under `artifacts/verification/`. A download site is optional. Add `web-page/` only if the user needs one. Select a license deliberately; do not copy Capture's license or website as an incidental bootstrap step.

Start `.gitignore` with:

```gitignore
.build/
DerivedData/
xcuserdata/
*.xcuserstate
*.xcscmblueprint
.DS_Store
*.dmg
release.env
Config/LocalSigning.xcconfig
artifacts/verification/
docs/dmg-backups/
```

Keep `docs/*.md`, shared schemes, asset catalog metadata, and reproducible brand sources tracked. Capture ignores all of `docs/`, which conflicts with committing iteration plans. Do not carry that inconsistency forward. Do not ignore all `.xcconfig` files.

Inspect an existing repository before initialization. Run `git init` only if needed. Preserve pre-existing changes and stage explicit paths rather than unrelated user work.

## 4. Make Xcode the authoritative app build

Create a standard Xcode project with three targets:

| Target | Type | Dependencies and membership |
| --- | --- | --- |
| `MyApp` | macOS application | App sources and assets; links and embeds `MyAppCore`. |
| `MyAppCore` | Framework | Domain state, transformations, and reusable operations. |
| `MyAppCoreTests` | XCTest unit-test bundle | Core tests; links `MyAppCore`; no app host required for core tests. |

Use Xcode's standard project format. You may adapt the reference project's small `project.pbxproj` and shared scheme, but remove all Capture source entries, product names, IDs, resources, and test references. Every referenced file and target must exist. Do not rely on user-local schemes. If using a project generator, make its input and exact regeneration command authoritative and documented; do not introduce that dependency by default.

For explicit Xcode file groups, add each new Swift file to the correct Sources phase. Files on disk are not automatically compiled. Link the framework and copy it into the app's Frameworks directory. Use `CodeSignOnCopy` for builds where Xcode signing is enabled. Ensure the app has an explicit dependency on the framework.

Configure these settings consistently:

| Setting | Instruction |
| --- | --- |
| `SDKROOT` | `macosx` |
| `MACOSX_DEPLOYMENT_TARGET` | Match the chosen minimum across every target. |
| `SWIFT_VERSION` | Choose one language mode across targets and optional package builds. Prefer Swift 6 for new code; implement actor isolation explicitly. |
| Debug optimization | `-Onone`; enable testability. |
| Release optimization | `-O`; use release debug symbols (`dwarf-with-dsym`). |
| `GENERATE_INFOPLIST_FILE` | `YES`, unless an explicit plist is necessary. |
| `PRODUCT_BUNDLE_IDENTIFIER` | Unique and stable for each target. |
| `PRODUCT_NAME` | Correct product name, without stale Capture values. |
| `ASSETCATALOG_COMPILER_APPICON_NAME` | `AppIcon` on the app target. |
| App runpath | `$(inherited) @executable_path/../Frameworks` |
| Core | `DEFINES_MODULE=YES`, `SKIP_INSTALL=YES` |
| App | `SKIP_INSTALL=NO` |
| Version | One shared `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` source for Debug and Release. |
| App metadata | Display name, appropriate category, copyright, and any required usage descriptions. |

Choose unsigned local builds with `CODE_SIGNING_ALLOWED=NO`. Developer ID release signing is a separate, explicit step below. If you support Xcode-managed signing, document which configuration uses it; do not silently combine signing strategies.

Create the main menu and windows in code. Do not leave an unused main storyboard or nib reference in the generated Info.plist. Do not add document types or permissions the product does not use.

Share the `MyApp` scheme in `xcshareddata/xcschemes/`. Build the app for running and archiving, and include the core test bundle in TestAction. Use Debug for tests and Release for archives. Validate immediately:

```bash
plutil -lint MyApp.xcodeproj/project.pbxproj
xcrun xcodebuild -list -project MyApp.xcodeproj
xcrun xcodebuild -showBuildSettings -project MyApp.xcodeproj -scheme MyApp
```

### Optional Swift package

Capture also has `Package.swift`, but its package tools version is 6.0 while Xcode uses Swift 5 language mode. Do not repeat that mismatch accidentally.

Add a package only if a second core-test entry point serves a real purpose. Prefer a core library and its tests; keep app resources, Info.plist, bundle assembly, and release builds under Xcode. Match the deployment target and language mode. If present, run `swift test` as well as Xcode tests. A package executable is not a substitute for the packaged `.app`.

## 5. Build the native application shell correctly

Keep responsibilities direct:

- `main.swift` creates `NSApplication.shared`, retains the delegate, sets regular activation policy, installs the menu, and starts the event loop.
- `AppDelegate` owns window controllers, creates windows, handles reopening, and coordinates application termination.
- `MainWindowController` owns one window's state, toolbar, file panels, and actions.
- Views draw and interpret local input. They call state operations rather than own persistence or application-wide behavior.
- `MyAppCore` contains behavior that can be tested without showing windows. Framework imports such as AppKit are acceptable where the domain needs native images or text; do not force artificial platform independence.

With Swift 6, isolate UI types and UI mutations to `@MainActor`. Keep background work limited to safe inputs and results, and return to the main actor for UI updates. Do not suppress concurrency diagnostics with broad unsafe annotations.

Retain every live window controller. Use weak captures for callbacks that would otherwise form cycles. Remove event monitors and observers when their owner closes or deinitializes. Verify that closed controllers can be released.

Choose last-window behavior intentionally. Capture terminates after its last window closes; a different app may stay open and recreate a window when its Dock icon is clicked. Implement and test the chosen behavior.

Use native menus, toolbars, file panels, standard symbols, and system typography. Include the applicable About, Quit, Hide, File, Edit, Window, and Help actions. The standard About panel should read the built bundle's version and copyright.

Route document/window actions through the responder chain. Menu and toolbar actions must operate on the active window. Preserve text editing commands when a text control has focus. Prefer menu key equivalents over event monitors; if a monitor is necessary, scope it to the correct window and return unhandled events.

Keep labels, symbols, tooltips, shortcuts, validation, and toolbar selection synchronized through a small shared definition. Disable unavailable actions. Provide accessible labels for icon-only controls and usable keyboard navigation. Do not add empty preferences, accounts, update services, or inspectors before the product needs them.

## 6. Keep state and output trustworthy

Use one state owner per independent window or document. Separate persisted content, selection, and transient interaction state. Model mutually exclusive interactions with an enum when that removes invalid combinations.

For editable products:

- Treat one user gesture as one undoable operation, not hundreds of drag updates.
- Skip undo entries and dirty-state changes for no-ops.
- Clear redo after a new edit; bound history when snapshots hold large data.
- Track the saved revision, so undo can return to a clean state.
- Commit active text editing before Save, Export, or Copy consumes the model.
- Keep Cancel non-destructive during close, replacement, or application quit.
- Test multi-window quit cancellation without losing changes in another window.
- Report write failures and preserve the user's previous file. Prefer atomic writes where supported.

Choose `NSDocument` when native document lifecycle, autosave, and restoration justify it. For a small utility, Capture's controller-owned state can be simpler. Do not implement both models without a reason.

For visual editors, preserve source-space coordinates and use a shared rendering path for the committed view and exported result. Zoom must not reduce output fidelity. Keep drag affordances transient. Cache expensive rendering with explicit invalidation. Test text, scale, clipping, transparency, and exported bounds where applicable.

Split large files by responsibility when it improves reasoning. Avoid speculative protocol layers, global mutable state, and broad rewrites. Add dependencies only when they replace substantial necessary work.

## 7. Provide a predictable command interface

Create a Makefile with these targets:

| Command | Required behavior |
| --- | --- |
| `make` / `make build` | Build Debug locally without requiring release credentials. |
| `make buildlocal` | Explicit unsigned Debug build. |
| `make test` | Run the shared scheme's tests without release credentials. |
| `make run` | Build and open the exact app in repository-local DerivedData. |
| `make assets` | Regenerate assets from tracked sources, if generators exist. |
| `make check-windows` | Run AppKit integration checks, when implemented. |
| `make release` | Produce and validate a signed, notarized DMG; do not upload a website. |
| `make paths` / `make help` | Show output paths and commands. |
| `make clean` | Remove only known generated files within this repository. |

Use overridable variables for project, scheme, configuration, destination, and DerivedData. Quote paths. Use actual tabs in Make recipes. Keep the default target explicit. Asset generation must finish before builds that consume it. Make routine builds incremental.

The underlying local commands should be:

```bash
xcrun xcodebuild -project MyApp.xcodeproj -scheme MyApp \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build

xcrun xcodebuild -project MyApp.xcodeproj -scheme MyApp \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO test

open -n .build/DerivedData/Build/Products/Debug/MyApp.app
```

If logging through `tee`, preserve the build's exit status with `pipefail`. Do not treat a matching log line as proof that the command passed. Avoid destructive global cleanup and automatic installation into `/Applications`.

## 8. Test behavior, then inspect the running app

Add focused XCTest cases for the first actual domain behavior, its boundary cases, and relevant failure paths. Test user-visible invariants rather than private implementation structure. Core tests should not require windows, a developer certificate, network access, or external sample files.

Use AppKit integration checks for behavior that core tests cannot establish: active-window routing, text focus, close cancellation, controller lifetime, and menu/toolbar consistency. Capture's `scripts/check_windows.sh` compiles app sources without `main.swift` and links the built core framework into a standalone runner. If adapting that method, use the chosen Swift language mode and a dedicated `@main` test entry point. An Xcode UI-test target is also appropriate when system interaction needs it.

Run UI checks in a logged-in GUI session. Their permissions and execution requirements differ from core tests. Wire the checks into a documented command so a passing `make test` cannot be mistaken for coverage it does not provide.

After automated checks:

1. Launch the exact built `.app`; avoid an older installed copy.
2. Exercise the primary workflow, cancellation, keyboard actions, and error handling.
3. Check minimum window size, long content, toolbar overflow, and multiple windows if supported.
4. Inspect the About panel, app icon, displayed version, and output files.
5. Capture and inspect visual evidence.

```bash
mkdir -p artifacts/verification
/usr/sbin/screencapture -x -D 1 artifacts/verification/first-launch.png
```

Capture the display that actually contains the app. A screenshot file alone is not visual verification: open it and inspect the result. If GUI access or Screen Recording permission blocks capture, report the limitation precisely; do not claim the verification passed. Do not kill another app instance containing unsaved user work.

## 9. Make brand assets reproducible

Keep editable icon and logo sources under `Brand/`. Capture uses SVG sources, a Swift renderer, `sips` for icon sizes, and a Swift DMG-background renderer. Reuse that approach when suitable, with the new app's artwork and names.

Generate the macOS AppIcon slots: 16, 32, 128, 256, and 512 points at both 1× and 2×. Include the 1024-pixel output. Keep `Contents.json` consistent with filenames. Check the icon at small sizes and in Finder; a large preview is insufficient.

Choose one policy: track generated icon PNGs, or generate them deterministically before every build that needs them. Both fresh-clone command-line and documented Xcode builds must work. Do not make the first build depend on files left in Capture's `.build` directory.

## 10. Reuse this Mac's signing setup safely

Track `Config/Signing.xcconfig` with:

```xcconfig
DEVELOPMENT_TEAM =
#include? "LocalSigning.xcconfig"
```

Track `Config/LocalSigning.example.xcconfig` with:

```xcconfig
DEVELOPMENT_TEAM = YOUR_EXISTING_TEAM_ID
```

If using these files, attach the shared configuration to the intended Xcode configurations. Files merely present in `Config/` do not change build settings. Confirm effective values with `-showBuildSettings`.

Track `release.env.example` using Makefile syntax:

```makefile
SIGN_IDENTITY = Developer ID Application: Existing Developer Name (TEAMID)
NOTARY_PROFILE = capture-notary
```

Load the ignored `release.env` through `-include` in Make. This is not a shell dotenv file: do not `source` it, and do not wrap its values in quotes. Pass values to release scripts as quoted arguments or explicit environment variables. Fail early when placeholders or required values remain unset.

The profile name `capture-notary` appears in Capture's examples. It is a candidate existing Keychain profile, not a verified credential. A working notarization profile can serve another app under the same account and team; its name need not match the new app.

To recover the correct setup, inspect only the necessary non-secret signing fields from the developer's existing local configuration, if available. Do not dump credential files or Keychain contents. Verify the identity with `security find-identity` and the candidate profile with:

```bash
xcrun notarytool history --keychain-profile "capture-notary"
```

This requires network and Keychain access. Confirm the selected signing identity and profile belong to the intended team. If access fails, distinguish missing credentials from a locked Keychain, network failure, or execution restriction. Ask for the specific missing setup only when necessary; continue unsigned app work independently.

If no reusable profile exists, use the interactive command:

```bash
xcrun notarytool store-credentials "mac-app-notary"
```

Let the developer enter existing account details and an app-specific password through the tool's prompts. Keep passwords, private keys, exported certificates, and API keys out of the repository and logs. Do not revoke or replace shared credentials as a troubleshooting shortcut.

## 11. Implement a complete local release pipeline

Direct distribution follows Apple's [Developer ID guidance](https://developer.apple.com/developer-id/) and [packaging workflow](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution). Keep packaging scripts explicit and fail on errors.

Before release, set the app version and build number in the authoritative build settings. Capture uses date versions, such as `2026.9.27`; semantic versions are also an option. Increment the build number for each published build. A Makefile variable used to name the DMG does not change the version inside the app. Read the built Info.plist and verify both values.

Build Release unsigned into a known directory. Set the intended architectures explicitly for distribution and verify the executable and embedded framework with `lipo -archs`. For a universal release, use `ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO` and confirm all dependencies support both. Do not infer Intel support from a successful build on this arm64 Mac.

Sign nested code before the enclosing app. For the default app-plus-framework layout, the essential commands are:

```bash
# These variables must be populated by the release driver.
# APP: absolute path to the Release .app
# CORE_NAME: e.g. MyAppCore
# SIGN_IDENTITY: verified existing Developer ID Application identity
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
  "$APP/Contents/Frameworks/$CORE_NAME.framework"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
```

Extend the explicit signing order when adding helpers, XPC services, or other embedded code. Do not copy Capture's `codesign --deep` signing shortcut into a general release pipeline. Recursive verification remains useful. Apply only the entitlements each executable needs. Ensure release code has no debug entitlement such as `get-task-allow`. App Sandbox and Hardened Runtime are different decisions; choose sandboxing based on app capabilities and distribution requirements.

For notarization, use Keychain profiles and `notarytool`. Require an `Accepted` result before proceeding, and retrieve the submission log on failure. Apple's [custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) explains submission logs and ticket stapling.

A thorough release sequence is:

1. Build and sign the app, including embedded code.
2. Create a temporary ZIP with `ditto -c -k --keepParent "$APP" "$ZIP"`.
3. Submit that ZIP with `xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait`.
4. After acceptance, staple and validate the app with `xcrun stapler staple "$APP"` and `xcrun stapler validate "$APP"`.
5. Package the stapled app into the final DMG.
6. Sign the DMG with `codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"`.
7. Submit the DMG with `xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait`.
8. After acceptance, staple and validate the DMG.
9. Verify signatures and Gatekeeper assessment of the app and DMG.

The app-first submission is an improvement over Capture's single DMG submission: it puts an app ticket inside the final disk image as well. Keep temporary ZIPs, submission logs, and release staging under `.build/release/`.

Final checks include:

```bash
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"
codesign --verify --verbose=2 "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
hdiutil verify "$DMG"
shasum -a 256 "$DMG"
```

A DMG should contain the app and an `/Applications` symlink. A branded background and Finder layout are optional polish. Capture's script uses `ditto`, `hdiutil`, and Finder AppleScript. If adapting it, validate all paths before deletion, confine staging to the repository, reject conflicting mount points, and trap cleanup so failures detach mounted images. Finder automation requires a GUI session and may request permission.

Mount the finished DMG and test the app copied from it. A build-directory launch does not verify packaging. Test a quarantined download on a clean account or another Mac when available, and record any environment you could not test. Never strip quarantine or disable Gatekeeper to make a distribution test pass.

Keep the last good release until the new artifact passes. Publish locally to a stable path such as `dist/MyApp.dmg` or `web-page/MyApp.dmg` only after validation, with timestamped ignored backups. Add the selected output directory to `.gitignore` as appropriate. Website upload, public release publication, and App Store submission are separate actions, not implicit side effects of `make release`.

## 12. Write project memory and iteration plans

Create `AGENTS.md` early. Include the product contract, source layout, exact commands, chosen window/persistence model, signing strategy, and these working rules:

- Implement the smallest coherent product slice first.
- Prefer native platform APIs and direct state changes over broad abstractions.
- Preserve user work and avoid unrelated changes.
- Add focused tests for behavior that can fail independently.
- Verify UI changes in the running built app and inspect screenshot evidence.
- Keep credentials local, plans tracked, and generated outputs isolated.
- Update commands and project memory when the architecture changes.
- Commit finished milestones with short messages when the task authorizes commits.

Each implementation iteration gets a new plan under `docs/`:

```text
YYYY-MM-DD-HH-MM-2-4-words-describing-iteration.md
```

Use `date +%Y-%m-%d-%H-%M` on this Mac to obtain the local timestamp. Do not overwrite older plans. Every plan contains:

1. Summary
2. Product behavior target
3. Architecture changes
4. UX acceptance criteria
5. Automated test plan
6. Manual verification plan
7. Assumptions and non-goals

If the user explicitly requests the Goal feature, use this objective, substituting the actual plan filename:

```text
Implement docs/<timestamped-plan-file>.md, creating focused tests and minimal meaningful commits for each milestone, then verify with xcrun xcodebuild and a screen capture artifact before marking the goal complete.
```

Do not create a Goal merely because this blueprint mentions one. For an authorized implementation goal, read the plan, implement, test, launch, inspect the screenshot, commit the completed milestones, and confirm a clean working tree. Report external blockers instead of claiming unperformed verification.

## 13. Finish the bootstrap with evidence

The first iteration is complete when:

- A fresh checkout can build through documented commands without release credentials or files from Capture.
- The shared scheme is discoverable and core tests pass.
- The app launches with the correct identity, menus, icon, and one useful end-to-end behavior.
- Window ownership, keyboard focus, close behavior, and relevant errors have been exercised.
- A screenshot of the actual built app has been inspected.
- `README.md` covers prerequisites, build, test, run, layout, assets, and release configuration.
- The first plan and `AGENTS.md` reflect the app actually built.
- `git diff --check` passes, changes are reviewed, and no credentials or build products are staged.
- Authorized commits contain only completed work; unrelated existing changes remain intact.

Release readiness is a separate milestone: it requires verified credentials, accepted notarization, valid tickets, and a tested final DMG. A new app can complete its initial development bootstrap before that milestone.

In the handoff, state what works, the exact tests performed, the app and screenshot paths, and any remaining limitation. Keep evidence separate from assumptions. The next agent should be able to continue from the repository without reconstructing this conversation.
