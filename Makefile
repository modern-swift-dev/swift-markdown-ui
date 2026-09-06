setup:

	brew bundle install
	brew upgrade
	brew cleanup
	brew autoremove
	mint bootstrap
	lefthook install

lint:

	mint run --no-install realm/SwiftLint lint --config .swiftlint.yml --strict --quiet

format-check:
	mint run --no-install nicklockwood/SwiftFormat . --config .swiftformat --lint --quiet

format:

	mint run --no-install nicklockwood/SwiftFormat . --config .swiftformat --quiet
	mint run --no-install realm/SwiftLint  --config .swiftlint.yml --fix --quiet

examples:

	cd Examples/Editor && xcodegen generate

SCHEME := MarkdownUI
SDK_VERSION := 26.5
IOS_SIMULATOR := platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5

test-macos:
	xcodebuild test -scheme $(SCHEME) -sdk macosx$(SDK_VERSION) -destination 'platform=macOS'

test-ios:
	xcodebuild test -scheme $(SCHEME) -sdk iphonesimulator$(SDK_VERSION) -destination "$(IOS_SIMULATOR)"

build-macos:
	xcodebuild build -scheme $(SCHEME) -sdk macosx$(SDK_VERSION) -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO

build-ios:
	xcodebuild build -scheme $(SCHEME) -sdk iphoneos$(SDK_VERSION) -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO

build-tvos:
	xcodebuild build -scheme $(SCHEME) -sdk appletvos$(SDK_VERSION) -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO

build-watchos:
	xcodebuild build -scheme $(SCHEME) -sdk watchos$(SDK_VERSION) -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO

build-visionos:
	xcodebuild build -scheme $(SCHEME) -sdk xros$(SDK_VERSION) -destination 'generic/platform=visionOS' CODE_SIGNING_ALLOWED=NO

build-maccatalyst:
	xcodebuild build -scheme $(SCHEME) -sdk macosx$(SDK_VERSION) -destination 'generic/platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO

test-all: test-macos test-ios

build-all: build-macos build-ios build-tvos build-watchos build-visionos build-maccatalyst

.PHONY: setup lint format format-check examples test-macos test-ios build-macos build-ios build-tvos build-watchos build-visionos build-maccatalyst test-all build-all
