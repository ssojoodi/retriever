# Universal build audit

## Summary
Verify the Release configuration and fresh-checkout build independence, then document remaining bootstrap gates.

## Product behavior target
The same repository builds an unsigned universal app without release credentials. Ordinary builds continue to be incremental Debug builds.

## Architecture changes
Add `make build-universal` and a bundle-architecture verification script. Keep Release verification products in a separate DerivedData directory. This command does not sign, notarize or publish a release.

## UX acceptance criteria
The built bundle retains Retriever's icon, identity and version. Both app and embedded framework contain arm64 and x86_64; minimum macOS remains 14.

## Automated test plan
Universal Release build, lipo architecture checks, Info.plist and deployment metadata checks. Build a fresh archive of committed source with no dependency on the existing .build directory.

## Manual verification plan
Intel runtime is not available on this host; no claim of tested Intel runtime. Existing built-app and connected-controller screenshots remain evidence only for their recorded scope.

## Assumptions and non-goals
No signing credentials or notarization in this iteration. Release readiness remains separate from development bootstrap.

## Evidence
- Unsigned universal Release build passed in `.build/ReleaseVerification`. App and embedded RetrieverCore framework both contain x86_64 and arm64, verified with lipo.
- App LC_BUILD_VERSION reports macOS 14.0 for both slices; bundle version is 0.1.0 (1) with AppIcon metadata/resources.
- `scripts/verify_universal.sh` passed on those products.
- A fresh `git archive HEAD` checkout at 3af9278 built through `make build` in a temporary directory with no prior .build output or local signing files. Temporary checkout cleaned up after success. Build log: `/tmp/retriever-fresh-build.log`.
- Added a requirement-by-requirement open-gate audit in `docs/bootstrap-acceptance.md`. Completion is still unproven, especially native save confirmation and packaged-app acceptance.
