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

site-setup:
	npm --prefix Website ci

site-preview: site-build
	./Scripts/preview-site.sh

site-build:
	./Scripts/build-site.sh

site-validate: site-setup
	npm --prefix Website run check
	SITE_SKIP_INSTALL=1 ./Scripts/build-site.sh
	./Scripts/check-links.py docs --base-path /swift-markdown-ui

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

.PHONY: setup lint format site-setup site-preview site-build site-validate test-macos test-ios build-ios build-tvos build-watchos build-visionos build-maccatalyst test-all build-all
