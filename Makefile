.PHONY: help tools format format-all lint lint-all build release size-check ci-check release-check notarized-dmg hooks-install

.DEFAULT_GOAL := help

PROJECT := SapoWhisper.xcodeproj
SCHEME := SapoWhisper
SWIFT_FORMAT := xcrun swift-format
SWIFT_FORMAT_CONFIG := .swift-format
SWIFT_SOURCE_DIR := SapoWhisper
DEBUG_DERIVED_DATA := ./build/audit-debug
RELEASE_DERIVED_DATA := ./build/audit-release
RELEASE_APP := $(RELEASE_DERIVED_DATA)/Build/Products/Release/SapoWhisper.app

help:
	@printf "SapoWhisper developer commands\n\n"
	@printf "  make tools         Check required local tools\n"
	@printf "  make format        Format changed Swift files with Xcode swift-format\n"
	@printf "  make format-all    Format all Swift sources explicitly\n"
	@printf "  make lint          Check changed Swift files without editing files\n"
	@printf "  make lint-all      Check all Swift sources explicitly\n"
	@printf "  make build         Build Debug for Apple Silicon\n"
	@printf "  make release       Build Release for Apple Silicon\n"
	@printf "  make size-check    Measure the Release app bundle\n"
	@printf "  make ci-check      Fast local gate: lint + Debug build\n"
	@printf "  make release-check Release gate: lint + Release build + size check\n"
	@printf "  make notarized-dmg Build, sign, notarize, staple, and validate the release DMG\n"
	@printf "  make hooks-install Install optional Lefthook git hooks\n"

tools:
	@xcrun --find swift-format >/dev/null
	@xcodebuild -version >/dev/null
	@printf "tools: xcodebuild and swift-format are available\n"

format: tools
	@scripts/swift_format_changed.sh format

format-all: tools
	$(SWIFT_FORMAT) format --in-place --recursive --parallel \
		--configuration $(SWIFT_FORMAT_CONFIG) \
		$(SWIFT_SOURCE_DIR)

lint: tools
	@scripts/swift_format_changed.sh lint

lint-all: tools
	$(SWIFT_FORMAT) lint --strict --recursive --parallel \
		--configuration $(SWIFT_FORMAT_CONFIG) \
		$(SWIFT_SOURCE_DIR)

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Debug -destination 'platform=macOS,arch=arm64' \
		-derivedDataPath $(DEBUG_DERIVED_DATA) build

release:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Release -destination 'generic/platform=macOS' \
		-derivedDataPath $(RELEASE_DERIVED_DATA) clean build

size-check:
	@scripts/measure_release_bundle.sh $(RELEASE_APP)

ci-check: lint build
	@printf "ci-check: passed\n"

release-check: lint release size-check
	@printf "release-check: passed\n"

notarized-dmg:
	@scripts/package_notarized_dmg.sh

hooks-install:
	@command -v lefthook >/dev/null || { echo "lefthook is not installed. Install it with: brew install lefthook"; exit 69; }
	lefthook install
