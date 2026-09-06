setup:

	brew bundle install
	brew upgrade
	brew cleanup
	brew autoremove
	mint bootstrap
	lefthook install

lint:

	mint run --no-install realm/SwiftLint  --config .swiftlint.yml --quiet

format:

	mint run --no-install nicklockwood/SwiftFormat . --config .swiftformat --quiet
	mint run --no-install realm/SwiftLint  --config .swiftlint.yml --fix --quiet

examples:

	cd Examples/Editor && xcodegen generate

SCHEME := MarkdownUI
IOS_SIMULATOR := platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5

test-macos:
	xcodebuild test -scheme $(SCHEME) -destination 'platform=macOS'

test-ios:
	xcodebuild test -scheme $(SCHEME) -destination "$(IOS_SIMULATOR)"

build-ios:
	xcodebuild build -scheme $(SCHEME) -destination 'generic/platform=iOS'

build-tvos:
	xcodebuild build -scheme $(SCHEME) -destination 'generic/platform=tvOS'

build-watchos:
	xcodebuild build -scheme $(SCHEME) -destination 'generic/platform=watchOS'

build-visionos:
	xcodebuild build -scheme $(SCHEME) -destination 'generic/platform=visionOS'

build-maccatalyst:
	xcodebuild build -scheme $(SCHEME) -destination 'generic/platform=macOS,variant=Mac Catalyst'

test-all: test-macos test-ios

build-all: build-ios build-tvos build-watchos build-visionos build-maccatalyst

.PHONY: setup lint format examples test-macos test-ios build-ios build-tvos build-watchos build-visionos build-maccatalyst test-all build-all
