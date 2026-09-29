.DEFAULT_GOAL := build
PROJECT ?= Retriever.xcodeproj
SCHEME ?= Retriever
CONFIGURATION ?= Debug
DESTINATION ?= platform=macOS
DERIVED_DATA ?= .build/DerivedData
APP = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Retriever.app
XCODE = xcrun xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration "$(CONFIGURATION)" -destination "$(DESTINATION)" -derivedDataPath "$(DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO
-include release.env
.PHONY: assets check-windows build buildlocal test run paths help release clean
build: buildlocal
buildlocal:
	$(XCODE) build
test:
	$(XCODE) test
run: build
	open -n "$(APP)"
check-windows:
	$(MAKE) build CONFIGURATION=Debug
	bash scripts/check_windows.sh "$(DERIVED_DATA)"
assets:
	mkdir -p .build/ModuleCache
	xcrun swift -module-cache-path .build/ModuleCache Brand/RenderIcon.swift
paths:
	@echo "App: $(APP)"
help:
	@echo "make build | test | check-windows | assets | run | paths | clean"
release:
	@echo "Release pipeline is not implemented yet; no distributable has been produced." >&2
	@exit 1
clean:
	$(XCODE) clean
