test-macos:
	xcodebuild test test \
			-workspace swift-markdown-ui.xcworkspace \
			-scheme MarkdownUI \
			-destination platform="macOS"

test-visionos:
	xcodebuild test test \
			-workspace swift-markdown-ui.xcworkspace \
			-scheme MarkdownUI \
			-destination platform="visionOS Simulator,name=Apple Vision Pro"

test-catalyst:
	xcodebuild test test \
			-workspace swift-markdown-ui.xcworkspace \
			-scheme MarkdownUI \
			-destination platform="macOS,variant=Mac Catalyst"

test-ios:
	xcodebuild test test \
			-workspace swift-markdown-ui.xcworkspace \
			-scheme MarkdownUI \
			-destination platform="iOS Simulator,name=iPhone SE (3rd generation)"

test-tvos:
	xcodebuild test test \
			-workspace swift-markdown-ui.xcworkspace \
			-scheme MarkdownUI \
			-destination platform="tvOS Simulator,name=Apple TV"

test-watchos:
	xcodebuild test test \
			-workspace swift-markdown-ui.xcworkspace \
			-scheme MarkdownUI \
			-destination platform="watchOS Simulator,name=Apple Watch SE (40mm) (2nd generation)"

test: test-macos test-catalyst test-ios test-tvos test-watchos

format:
	swift format --in-place --recursive .

.PHONY: format
