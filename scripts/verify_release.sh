#!/bin/bash
set -euo pipefail
app="${1:?Pass the built Retriever.app path}"
for binary in "$app/Contents/MacOS/Retriever" "$app/Contents/Frameworks/RetrieverCore.framework/Versions/A/RetrieverCore"; do
    [[ "$(xcrun lipo -archs "$binary")" == "arm64" ]]
    sections=$(xcrun size -m "$binary")
    if grep -Eq 'Section __llvm_(cov|prf)' <<< "$sections"; then
        echo "Release binary contains LLVM coverage instrumentation: $binary" >&2
        exit 1
    fi
done
identifier=$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")
[[ "$identifier" == "ca.sahand.Retriever" ]]
[[ -f "$app/Contents/Resources/AppIcon.icns" ]]
echo "Verified Apple silicon Retriever app and embedded framework. Unsigned; not a distributable release."
