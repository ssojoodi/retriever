#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
products="${1:-.build/DerivedData}/Build/Products/Debug"
if [[ ! -d "$products/RetrieverCore.framework" ]]; then
  echo "Build the Debug app first with make build DERIVED_DATA=${1:-.build/DerivedData}." >&2
  exit 1
fi
mkdir -p .build/checks
xcrun swiftc -swift-version 6 -F "$products" -framework RetrieverCore -framework AppKit \
  -Xlinker -rpath -Xlinker "$(cd "$products" && pwd)" \
  Sources/RetrieverApp/AppDelegate.swift Sources/RetrieverApp/AppMenu.swift \
  Sources/RetrieverApp/ConnectionSheet.swift Sources/RetrieverApp/MainWindowController.swift \
  Sources/RetrieverApp/SSHAskpass.swift Tests/RetrieverAppChecks/WebsiteScreenshots.swift \
  -o .build/checks/WebsiteScreenshots
LLVM_PROFILE_FILE=".build/checks/website-screenshots-%p.profraw" .build/checks/WebsiteScreenshots
