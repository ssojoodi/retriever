.DEFAULT_GOAL := build
PROJECT ?= Retriever.xcodeproj
SCHEME ?= Retriever
CONFIGURATION ?= Debug
DESTINATION ?= platform=macOS
DERIVED_DATA ?= .build/DerivedData
UNIVERSAL_DERIVED_DATA ?= .build/ReleaseVerification
APP = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Retriever.app
XCODE = xcrun xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration "$(CONFIGURATION)" -destination "$(DESTINATION)" -derivedDataPath "$(DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO
-include release.env
.PHONY: build-universal check-browser check-ssh assets check-windows build buildlocal test run paths help release clean
build: buildlocal
build-universal:
	xcrun xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Release -destination "generic/platform=macOS" -derivedDataPath "$(UNIVERSAL_DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO "ARCHS=arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
	bash scripts/verify_universal.sh "$(UNIVERSAL_DERIVED_DATA)/Build/Products/Release/Retriever.app"
buildlocal:
	$(XCODE) build
test:
	$(XCODE) test
run: build
	open -n "$(APP)"
check-browser:
	$(MAKE) build CONFIGURATION=Debug
	python3 scripts/check_ssh.py "$(DERIVED_DATA)" --gui
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
help:
	@echo "make build | build-universal | test | check-windows | check-ssh | check-browser | assets | run | paths | release | clean"
release:
	python3 scripts/release.py --identity "$(SIGN_IDENTITY)" --profile "$(NOTARY_PROFILE)"
clean:
	$(XCODE) clean
