SHELL := /bin/bash

# Override with a shell-quoted file list to check only changed Swift files.
SWIFT_FILES ?= .

setup:

	brew bundle install
	brew upgrade
	brew cleanup
	brew autoremove
	mint bootstrap
	lefthook install

lint: lint-workflows

	mint run --no-install realm/SwiftLint lint --config .swiftlint.yml --strict --quiet --force-exclude $(SWIFT_FILES)

format-check:
	mint run --no-install nicklockwood/SwiftFormat $(SWIFT_FILES) --config .swiftformat --lint --quiet

format:

	mint run --no-install nicklockwood/SwiftFormat $(SWIFT_FILES) --config .swiftformat --quiet
	mint run --no-install realm/SwiftLint lint --config .swiftlint.yml --fix --quiet --force-exclude $(SWIFT_FILES)

examples:

	cd Examples/Editor && xcodegen generate

SCHEME := MarkdownUI
SDK_VERSION := 26.5
IOS_SIMULATOR := platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5

test-macos:
	set -o pipefail && xcodebuild test -scheme $(SCHEME) -sdk macosx$(SDK_VERSION) -destination 'platform=macOS' 2>&1 | mint run --no-install cpisciotta/xcbeautify -q

test-ios:
	set -o pipefail && xcodebuild test -scheme $(SCHEME) -sdk iphonesimulator$(SDK_VERSION) -destination "$(IOS_SIMULATOR)" 2>&1 | mint run --no-install cpisciotta/xcbeautify -q

build-macos:
	set -o pipefail && xcodebuild build -scheme $(SCHEME) -sdk macosx$(SDK_VERSION) -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | mint run --no-install cpisciotta/xcbeautify -q

build-ios:
	set -o pipefail && xcodebuild build -scheme $(SCHEME) -sdk iphoneos$(SDK_VERSION) -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO 2>&1 | mint run --no-install cpisciotta/xcbeautify -q

build-tvos:
	set -o pipefail && xcodebuild build -scheme $(SCHEME) -sdk appletvos$(SDK_VERSION) -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO 2>&1 | mint run --no-install cpisciotta/xcbeautify -q

build-watchos:
	set -o pipefail && xcodebuild build -scheme $(SCHEME) -sdk watchos$(SDK_VERSION) -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO 2>&1 | mint run --no-install cpisciotta/xcbeautify -q

build-visionos:
	set -o pipefail && xcodebuild build -scheme $(SCHEME) -sdk xros$(SDK_VERSION) -destination 'generic/platform=visionOS' CODE_SIGNING_ALLOWED=NO 2>&1 | mint run --no-install cpisciotta/xcbeautify -q

build-maccatalyst:
	set -o pipefail && xcodebuild build -scheme $(SCHEME) -sdk macosx$(SDK_VERSION) -destination 'generic/platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO 2>&1 | mint run --no-install cpisciotta/xcbeautify -q

test: test-all

test-all: test-macos test-ios

build-all: build-macos build-ios build-tvos build-watchos build-visionos build-maccatalyst

.PHONY: setup lint format format-check examples test test-macos test-ios build-macos build-ios build-tvos build-watchos build-visionos build-maccatalyst test-all build-all

.PHONY: lint-workflows

lint-workflows:
	actionlint
