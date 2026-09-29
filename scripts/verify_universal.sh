#!/bin/bash
set -euo pipefail
app="${1:?Pass the built Retriever.app path}"
for binary in "$app/Contents/MacOS/Retriever" "$app/Contents/Frameworks/RetrieverCore.framework/Versions/A/RetrieverCore"; do
    xcrun lipo "$binary" -verify_arch arm64 x86_64
done
identifier=$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")
[[ "$identifier" == "ca.sahand.Retriever" ]]
[[ -f "$app/Contents/Resources/AppIcon.icns" ]]
echo "Verified universal Retriever app and embedded framework. Unsigned; not a distributable release."
