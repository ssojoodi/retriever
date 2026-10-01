#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
derived_data="${1:-.build/DerivedData}"
products="$derived_data/Build/Products/Debug"
mkdir -p .build/checks
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macos14.0" \
  -F "$products" -framework RetrieverCore -framework AppKit \
  -Xlinker -rpath -Xlinker "$(cd "$products" && pwd)" \
  Sources/RetrieverApp/AppDelegate.swift Sources/RetrieverApp/AppMenu.swift \
  Sources/RetrieverApp/ConnectionSheet.swift Sources/RetrieverApp/DownloadsWindowController.swift Sources/RetrieverApp/MainWindowController.swift Sources/RetrieverApp/SSHAskpass.swift Tests/RetrieverAppChecks/WindowChecks.swift \
  -o .build/checks/WindowChecks
LLVM_PROFILE_FILE=".build/checks/window-checks-%p.profraw" .build/checks/WindowChecks
