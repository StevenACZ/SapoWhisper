.PHONY: help tools format format-all lint lint-all build test script-tests release install-dev size-check artifact-check secrets-scan release-input-check ci-check release-check notarized-dmg appcast hooks-install idle-cpu-note

.DEFAULT_GOAL := help

PROJECT := SapoWhisper.xcodeproj
SCHEME := SapoWhisper
SWIFT_FORMAT := xcrun swift-format
SWIFT_FORMAT_CONFIG := .swift-format
SWIFT_SOURCE_DIR := SapoWhisper
DEBUG_DERIVED_DATA := ./build/audit-debug
RELEASE_DERIVED_DATA := ./build/audit-release
RELEASE_APP := $(RELEASE_DERIVED_DATA)/Build/Products/Release/SapoWhisper.app
RELEASE_C_PATH_FLAGS := -fmacro-prefix-map=$(CURDIR)=.
# mlx-swift ships a build plugin (CudaBuild); headless xcodebuild cannot
# answer the interactive plugin-trust prompt, so validation is skipped here.
XCODE_FLAGS := -skipPackagePluginValidation -skipMacroValidation

help:
	@printf "SapoWhisper developer commands\n\n"
	@printf "  make tools         Check required local tools\n"
	@printf "  make format        Format changed Swift files with Xcode swift-format\n"
	@printf "  make format-all    Format all Swift sources explicitly\n"
	@printf "  make lint          Check changed Swift files without editing files\n"
	@printf "  make lint-all      Check all Swift sources explicitly\n"
	@printf "  make build         Build Debug for Apple Silicon\n"
	@printf "  make test          Run unit tests\n"
	@printf "  make script-tests  Run benchmark script contract tests\n"
	@printf "  make release       Build Release for Apple Silicon\n"
	@printf "  make install-dev   Reinstall signed Release build to /Applications\n"
	@printf "  make size-check    Measure the Release app bundle\n"
	@printf "  make artifact-check Verify identity, architecture, paths, and contents\n"
	@printf "  make secrets-scan  Scan source plus exact tracked audio allowlist (fixtures + app sounds)\n"
	@printf "  make release-input-check Verify project identity and synchronized source inputs\n"
	@printf "  make ci-check      Local gate: lint + secret/audio scan + script tests + Debug build + tests\n"
	@printf "  make release-check Release gate: lint + Release build + size + artifact checks\n"
	@printf "  make notarized-dmg Build, sign, notarize, staple, and validate the release DMG\n"
	@printf "  make appcast       Zip the notarized app, EdDSA-sign it, and write appcast.xml\n"
	@printf "  make hooks-install Install optional Lefthook git hooks\n"
	@printf "  make idle-cpu-note Print the manual idle-CPU verification steps (R6)\n"

idle-cpu-note:
	@printf "Idle CPU manual check (R6) - the app must sit at 0%% CPU while idle:\n"
	@printf "  1. Launch the Release app and leave it idle in the menu bar (no recording,\n"
	@printf "     Settings/History/Welcome closed, overlay hidden).\n"
	@printf "  2. Run: top -pid \"\x24(pgrep -x SapoWhisper)\" -stats cpu -l 30 | tail -25\n"
	@printf "     Expected: 0.0%% on virtually every sample.\n"
	@printf "  3. Repeat after a sleep/wake cycle and after 24h of residency.\n"
	@printf "  4. Deeper pass: Instruments Time Profiler for 5 idle minutes; only the\n"
	@printf "     10-min hotkey watchdog and the daily RSS tick may fire.\n"
	@printf "Timer inventory (all activity-gated): recorder/streaming 0.1s timers only\n"
	@printf "while capturing; AudioLevelMonitor only while the Settings audio UI is\n"
	@printf "visible; overlay polish countdown only while that pill is visible;\n"
	@printf "permission/welcome refresh timers only while those windows exist.\n"

tools:
	@xcrun --find swift-format >/dev/null
	@xcodebuild -version >/dev/null
	@command -v gitleaks >/dev/null || { printf "gitleaks is required (brew install gitleaks)\n" >&2; exit 69; }
	@printf "tools: xcodebuild, swift-format, and gitleaks are available\n"

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
		-derivedDataPath $(DEBUG_DERIVED_DATA) $(XCODE_FLAGS) build

test:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Debug -destination 'platform=macOS,arch=arm64' \
		-derivedDataPath $(DEBUG_DERIVED_DATA) $(XCODE_FLAGS) test

script-tests:
	bash -n scripts/local_stt_benchmark.sh
	bash scripts/test_secrets_scan.sh
	python3 scripts/test_stt_benchmark_vocabulary.py
	python3 scripts/test_ai_polish_history_replay.py

release:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Release -destination 'generic/platform=macOS' \
		-derivedDataPath $(RELEASE_DERIVED_DATA) $(XCODE_FLAGS) \
		OTHER_CFLAGS='$$(inherited) $(RELEASE_C_PATH_FLAGS)' \
		OTHER_CPLUSPLUSFLAGS='$$(inherited) $(RELEASE_C_PATH_FLAGS)' clean build

install-dev:
	@chmod +x scripts/install_dev.sh
	@scripts/install_dev.sh

size-check:
	@scripts/measure_release_bundle.sh $(RELEASE_APP)

artifact-check:
	@scripts/verify_release_app.sh $(RELEASE_APP)

secrets-scan:
	@scripts/secrets_scan.sh tree
	@bash scripts/verify_public_audio_allowlist.sh

release-input-check:
	@scripts/verify_release_inputs.sh >/dev/null

ci-check: lint secrets-scan script-tests build test
	@printf "ci-check: passed\n"

release-check: release-input-check lint release size-check artifact-check
	@printf "release-check: passed\n"

notarized-dmg: release-input-check
	@scripts/package_notarized_dmg.sh

appcast:
	@scripts/generate_appcast.sh

hooks-install:
	@command -v lefthook >/dev/null || { echo "lefthook is not installed. Install it with: brew install lefthook"; exit 69; }
	lefthook install
