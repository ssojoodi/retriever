# Reproducible app icon

## Summary
Give Retriever a distinct, reproducible icon and complete the missing asset-generation command.

## Product behavior target
Finder, Dock and About show Retriever's own icon. Both a fresh Xcode checkout and command-line build have all required icon sizes.

## Architecture changes
Track a small AppKit vector renderer under Brand and its generated PNGs in the asset catalog. `make assets` regenerates all ten macOS icon slots. Ordinary builds use the tracked assets without extra tooling.

## UX acceptance criteria
A restrained golden folder with a clear retrieval arrow, readable at 16 and 32 points. Rounded app tile with transparent outer corners. No copied Cyberduck branding.

## Automated test plan
Regenerate twice and compare file hashes; validate PNG dimensions and slot metadata. Build unsigned and check compiled bundle icon metadata.

## Manual verification plan
Inspect a contact sheet of all raster sizes and the built app's About icon. Record any GUI checks still pending.

## Assumptions and non-goals
This finishes branding infrastructure, not authenticated SFTP acceptance or notarized distribution. Brand source is native vector drawing code; no external asset dependency.

## Evidence
- `make assets` completed twice with identical SHA-256 hashes for every output. All ten PNG dimensions match their catalog slots.
- Inspected 16-, 32- and 1024-pixel rasters directly; folder and retrieval arrow remain recognizable. A contact sheet was not needed for these individual inspections.
- Unsigned Xcode Debug build passed. Built Info.plist references AppIcon and the bundle contains AppIcon.icns and Assets.car, version 0.1.0 (1).
- Relaunched the exact built app. About menu automation failed with macOS assistive-access error -1719. Inspected `artifacts/verification/retriever-about-icon.png`: it shows the app and Accessibility prompt, not the About panel. About/Finder/Dock visual verification remains pending; do not treat this screenshot as evidence for it.
