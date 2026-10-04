.DEFAULT_GOAL := build
PROJECT ?= Retriever.xcodeproj
SCHEME ?= Retriever
CONFIGURATION ?= Debug
DESTINATION ?= platform=macOS
DERIVED_DATA ?= .build/DerivedData
RELEASE_DERIVED_DATA ?= .build/ReleaseVerification
APP = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Retriever.app
RELEASE_FLAGS = SWIFT_OPTIMIZATION_LEVEL=-Osize
XCODE_FLAGS ?=
XCODE = xcrun xcodebuild $(XCODE_FLAGS) $(if $(filter Release,$(CONFIGURATION)),$(RELEASE_FLAGS)) -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration "$(CONFIGURATION)" -destination "$(DESTINATION)" -derivedDataPath "$(DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO
-include release.env
.PHONY: check-transfers build-release check-terminal check-browser check-ssh assets check-windows build buildlocal test run paths help release clean
build: buildlocal
build-release:
	xcrun xcodebuild $(XCODE_FLAGS) $(RELEASE_FLAGS) -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Release -destination "generic/platform=macOS" -derivedDataPath "$(RELEASE_DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO "ARCHS=arm64" ONLY_ACTIVE_ARCH=NO build
	bash scripts/verify_release.sh "$(RELEASE_DERIVED_DATA)/Build/Products/Release/Retriever.app"
buildlocal:
	$(XCODE) build
test:
	$(XCODE) test
run: build
	open -n "$(APP)"
check-browser:
	$(MAKE) build CONFIGURATION=Debug
	python3 scripts/check_ssh.py "$(DERIVED_DATA)" --gui
check-transfers:
	$(MAKE) build CONFIGURATION=Debug
	bash scripts/check_transfers.sh "$(DERIVED_DATA)"
check-terminal:
	$(MAKE) build CONFIGURATION=Debug
	python3 scripts/check_ssh.py "$(DERIVED_DATA)" --terminal
check-ssh:
	$(MAKE) build CONFIGURATION=Debug
	python3 scripts/check_ssh.py "$(DERIVED_DATA)"
check-windows:
	$(MAKE) build CONFIGURATION=Debug
	bash scripts/check_windows.sh "$(DERIVED_DATA)"
assets:
	mkdir -p .build/ModuleCache
	xcrun swift -module-cache-path .build/ModuleCache Brand/RenderIcon.swift
paths:
	@echo "App: $(APP)"
	@echo "DMG: web-page/Retriever.dmg"
	@echo "DMG backups: docs/dmg-backups/"
help:
	@echo "make build | build-release | test | check-windows | check-ssh | check-browser | check-terminal | check-transfers | assets | run | paths | release | clean"
release:
	python3 scripts/release.py --identity "$(SIGN_IDENTITY)" --profile "$(NOTARY_PROFILE)"
clean:
	$(XCODE) clean
