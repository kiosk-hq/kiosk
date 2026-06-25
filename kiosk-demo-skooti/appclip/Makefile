# Makefile — Skooti App Clip (appclip/)
#
# Prerequisites:
#   brew install xcodegen
#   Xcode 15+ with iOS 17+ SDK
#
# ── Bundle prefix / team override ────────────────────────────────────────────
# Override without editing project.yml:
#   BUNDLE_PREFIX=app.skooti.personal make project
#   DEVELOPMENT_TEAM=ABCDE12345 make project
#
# ── Targets ──────────────────────────────────────────────────────────────────
#   make project      — generate SkootiDemo.xcodeproj via xcodegen
#   make build-sim    — compile for iOS Simulator (no signing required)
#   make build-device — compile for device (requires DEVELOPMENT_TEAM=TEAMID)
#   make open         — open SkootiDemo.xcodeproj in Xcode
#   make clean        — remove generated .xcodeproj and DerivedData
#
# Note: App Clips require a paid Apple Developer Program account and a
# physical iPhone for BLE testing.  The Simulator build (build-sim) is
# sufficient to verify the Swift code compiles.  BLE to a real ESP32-C3
# requires an actual device.

XCODEPROJ := SkootiDemo.xcodeproj
SCHEME     := Skooti

# Export so xcodegen can read them as environment variables for ${VAR:default}
export BUNDLE_PREFIX    ?= app.skooti.demo
export DEVELOPMENT_TEAM ?=

.PHONY: project build-sim build-device open clean

## Generate SkootiDemo.xcodeproj (GENERATED — gitignored; re-run after editing project.yml)
project:
	xcodegen generate --spec project.yml
	@echo ""
	@echo "Project generated: $(XCODEPROJ)"
	@echo "Run 'make open' to open in Xcode, or 'make build-sim' to compile-check."

## Compile-check for iOS Simulator (no code signing required)
## Note: App Clip BLE and NFC require a real device; this target verifies the Swift code compiles.
build-sim: $(XCODEPROJ)
	xcodebuild \
	  -project $(XCODEPROJ) \
	  -scheme $(SCHEME) \
	  -sdk iphonesimulator \
	  -destination 'generic/platform=iOS Simulator' \
	  CODE_SIGNING_ALLOWED=NO \
	  build \
	  | xcpretty || xcodebuild \
	    -project $(XCODEPROJ) \
	    -scheme $(SCHEME) \
	    -sdk iphonesimulator \
	    -destination 'generic/platform=iOS Simulator' \
	    CODE_SIGNING_ALLOWED=NO \
	    build

## Build for device (requires a paid Apple Developer account)
## Usage: DEVELOPMENT_TEAM=ABCDE12345 make build-device
## Add -allowProvisioningUpdates to let xcodebuild register the device and download profiles.
build-device: $(XCODEPROJ)
	@if [ -z "$(DEVELOPMENT_TEAM)" ]; then \
	  echo "ERROR: DEVELOPMENT_TEAM is not set."; \
	  echo "Usage: DEVELOPMENT_TEAM=ABCDE12345 make build-device"; \
	  exit 1; \
	fi
	xcodebuild \
	  -project $(XCODEPROJ) \
	  -scheme $(SCHEME) \
	  -sdk iphoneos \
	  -destination 'generic/platform=iOS' \
	  DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM) \
	  -allowProvisioningUpdates \
	  build

## Open SkootiDemo.xcodeproj in Xcode
open: $(XCODEPROJ)
	open $(XCODEPROJ)

## Remove generated project and build artifacts
clean:
	rm -rf $(XCODEPROJ)
	rm -rf ~/Library/Developer/Xcode/DerivedData/SkootiDemo-*
	@echo "Cleaned."

# Regenerate if project.yml is newer than the .xcodeproj
$(XCODEPROJ): project.yml
	$(MAKE) project
