#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
products="${1:-.build/DerivedData}/Build/Products/Debug"
mkdir -p .build/checks
xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0 -F "$products" -framework RetrieverCore \
  -Xlinker -rpath -Xlinker "$(cd "$products" && pwd)" \
  Sources/RetrieverApp/TransferCoordinator.swift Tests/RetrieverAppChecks/TransferChecks.swift \
  -o .build/checks/TransferChecks
LLVM_PROFILE_FILE=".build/checks/transfer-checks-%p.profraw" .build/checks/TransferChecks
