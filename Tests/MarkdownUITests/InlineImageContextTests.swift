#if os(macOS)
    import AppKit
    @testable import MarkdownUI
    import SwiftUI
    import XCTest

    final class InlineImageContextTests: XCTestCase {
        func testBuiltInProviderIdentityIsStable() {
            XCTAssertEqual(
                InlineImageProviderContext(provider: .default).id,
                InlineImageProviderContext(provider: .default).id
            )
            XCTAssertEqual(
                InlineImageProviderContext(provider: .asset).id,
                InlineImageProviderContext(provider: .asset).id
            )
            let asset = AssetInlineImageProvider(name: { $0.path })
            XCTAssertEqual(
                InlineImageProviderContext(provider: asset).id,
                InlineImageProviderContext(provider: asset).id
            )
        }

        func testHashableAndDefaultAssetProvidersAreIdentifiedByValue() {
            func id(_ provider: any InlineImageProvider) -> InlineImageProviderContext.ID {
                InlineImageProviderContext(provider: provider).id
            }
            let recording = RecordingInlineImageProvider()
            XCTAssertEqual(
                id(HashableInlineImageProvider(tag: 1, recording: recording)),
                id(HashableInlineImageProvider(tag: 1, recording: recording))
            )
            XCTAssertNotEqual(
                id(HashableInlineImageProvider(tag: 1, recording: recording)),
                id(HashableInlineImageProvider(tag: 2, recording: recording))
            )
            XCTAssertNotEqual(
                id(HashableInlineImageProvider(tag: 1, recording: recording)),
                id(OtherHashableInlineImageProvider(tag: 1))
            )

            XCTAssertEqual(id(AssetInlineImageProvider()), id(AssetInlineImageProvider()))
            XCTAssertEqual(id(AssetInlineImageProvider(bundle: .main)), id(AssetInlineImageProvider(bundle: .main)))
            XCTAssertEqual(id(AssetInlineImageProvider()), id(.asset))
            let testBundle = Bundle(for: Self.self)
            XCTAssertNotEqual(id(AssetInlineImageProvider(bundle: .main)), id(AssetInlineImageProvider(bundle: testBundle)))
            // Closures can't be compared, so each custom name mapping keeps its own identity.
            XCTAssertNotEqual(
                id(AssetInlineImageProvider(name: \.lastPathComponent, bundle: .main)),
                id(AssetInlineImageProvider(name: \.lastPathComponent, bundle: .main))
            )
        }

        @MainActor func testRecreatedHashableProviderDoesNotReloadAfterParentUpdate() async throws {
            let model = ImageContextModel()
            let recording = RecordingInlineImageProvider()
            let hostingView = NSHostingView(rootView: ImageContextView(model: model).padding(0)
                .markdownInlineImageProvider(HashableInlineImageProvider(tag: 1, recording: recording)))
            let window = self.host(hostingView)
            defer { window.contentView = nil }

            try await self.waitForRequest("https://example.com/first/logo.png", from: recording)
            hostingView.rootView = ImageContextView(model: model).padding(10)
                .markdownInlineImageProvider(HashableInlineImageProvider(tag: 1, recording: recording))
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let requests = await recording.requests
            XCTAssertEqual(requests, ["https://example.com/first/logo.png"])
        }

        @MainActor func testReusingProviderDoesNotReloadAfterParentUpdate() async throws {
            let model = ImageContextModel()
            let provider = RecordingInlineImageProvider()
            let hostingView = NSHostingView(
                rootView: ImageContextView(model: model).padding(0).markdownInlineImageProvider(provider)
            )
            let window = self.host(hostingView)
            defer { window.contentView = nil }

            try await self.waitForRequest("https://example.com/first/logo.png", from: provider)
            hostingView.rootView = ImageContextView(model: model).padding(10).markdownInlineImageProvider(provider)
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let requests = await provider.requests
            XCTAssertEqual(requests, ["https://example.com/first/logo.png"])
        }

        @MainActor func testTextOnlyEditDoesNotReloadImagesAndAltEditDoes() async throws {
            let model = ImageContextModel()
            let provider = RecordingInlineImageProvider()
            let hostingView = NSHostingView(
                rootView: ImageContextView(model: model).markdownInlineImageProvider(provider)
            )
            let window = self.host(hostingView)
            defer { window.contentView = nil }
            try await self.waitForRequest("https://example.com/first/logo.png", from: provider)
            model.markdown = "edited neighboring text ![alt](logo.png)"
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let requests = await provider.requests
            XCTAssertEqual(requests.count, 1)
            model.markdown = "edited neighboring text ![new label](logo.png)"
            hostingView.layoutSubtreeIfNeeded()
            for _ in 0 ..< 100 {
                if await provider.labels.contains("new label") {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let labels = await provider.labels
            XCTAssertEqual(labels, ["alt", "new label"])
        }

        @MainActor func testAddingImagesLoadsOnlyMissingImages() async throws {
            let model = ImageContextModel()
            let provider = RecordingInlineImageProvider()
            let hostingView = NSHostingView(
                rootView: ImageContextView(model: model).markdownInlineImageProvider(provider)
            )
            let window = self.host(hostingView)
            defer { window.contentView = nil }
            try await self.waitForRequest("https://example.com/first/logo.png", from: provider)
            // Allow the result to reach the view before changing the requested image set.
            try await Task.sleep(for: .milliseconds(100))

            model.markdown = "before ![alt](logo.png) ![second](second.png) after"
            hostingView.layoutSubtreeIfNeeded()
            try await self.waitForRequest("https://example.com/first/second.png", from: provider)
            try await Task.sleep(for: .milliseconds(100))
            model.markdown += " ![third](third.png)"
            hostingView.layoutSubtreeIfNeeded()
            try await self.waitForRequest("https://example.com/first/third.png", from: provider)
            try await Task.sleep(for: .milliseconds(100))

            let requests = await provider.requests
            XCTAssertEqual(requests, [
                "https://example.com/first/logo.png",
                "https://example.com/first/second.png",
                "https://example.com/first/third.png"
            ])
        }

        @MainActor func testRemovedImagesAreReleasedAndLoadedAgainWhenReinserted() async throws {
            let model = ImageContextModel()
            let provider = RecordingInlineImageProvider()
            let hostingView = NSHostingView(
                rootView: ImageContextView(model: model).markdownInlineImageProvider(provider)
            )
            let window = self.host(hostingView)
            defer { window.contentView = nil }
            try await self.waitForRequest("https://example.com/first/logo.png", from: provider)
            try await Task.sleep(for: .milliseconds(100))
            model.markdown = "before ![alt](logo.png) ![second](second.png) after"
            hostingView.layoutSubtreeIfNeeded()
            try await self.waitForRequest("https://example.com/first/second.png", from: provider)
            try await Task.sleep(for: .milliseconds(100))

            model.markdown = "before ![second](second.png) after"
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            model.markdown = "before ![alt](logo.png) ![second](second.png) after"
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let afterReinsert = await provider.labels
            XCTAssertEqual(afterReinsert, ["alt", "second", "alt"])

            model.markdown = "before no images after"
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            model.markdown = "before ![second](second.png) after"
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let afterEmpty = await provider.labels
            XCTAssertEqual(afterEmpty, ["alt", "second", "alt", "second"])
        }

        @MainActor func testExplicitValueProviderIdentityPreservesImagesAndInvalidatesConfiguration() async throws {
            let model = ImageContextModel()
            let recording = RecordingInlineImageProvider()
            let hostingView = NSHostingView(rootView: ImageContextView(model: model)
                .markdownInlineImageProvider(ValueInlineImageProvider(recording: recording), id: 1))
            let window = self.host(hostingView)
            defer { window.contentView = nil }
            try await self.waitForRequest("https://example.com/first/logo.png", from: recording)
            hostingView.rootView = ImageContextView(model: model)
                .markdownInlineImageProvider(ValueInlineImageProvider(recording: recording), id: 1)
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let initialRequests = await recording.requests
            XCTAssertEqual(initialRequests.count, 1)
            hostingView.rootView = ImageContextView(model: model)
                .markdownInlineImageProvider(ValueInlineImageProvider(recording: recording), id: 2)
            hostingView.layoutSubtreeIfNeeded()
            for _ in 0 ..< 100 {
                if await recording.requests.count == 2 {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let requests = await recording.requests
            XCTAssertEqual(requests.count, 2)
        }

        @MainActor func testChangingImageBaseURLReloadsUnchangedMarkdown() async throws {
            let model = ImageContextModel()
            let provider = RecordingInlineImageProvider()
            let hostingView = NSHostingView(
                rootView: ImageContextView(model: model).markdownInlineImageProvider(provider)
            )
            let window = self.host(hostingView)
            defer { window.contentView = nil }

            try await self.waitForRequest("https://example.com/first/logo.png", from: provider)
            model.baseURL = URL(string: "https://example.com/second/")
            hostingView.layoutSubtreeIfNeeded()
            try await self.waitForRequest("https://example.com/second/logo.png", from: provider)
        }

        @MainActor func testReplacingInlineImageProviderReloadsUnchangedMarkdown() async throws {
            let model = ImageContextModel()
            let first = RecordingInlineImageProvider()
            let second = RecordingInlineImageProvider()
            let hostingView = NSHostingView(
                rootView: ImageContextView(model: model).markdownInlineImageProvider(first)
            )
            let window = self.host(hostingView)
            defer { window.contentView = nil }

            try await self.waitForRequest("https://example.com/first/logo.png", from: first)
            hostingView.rootView = ImageContextView(model: model).markdownInlineImageProvider(second)
            hostingView.layoutSubtreeIfNeeded()
            try await self.waitForRequest("https://example.com/first/logo.png", from: second)
        }

        @MainActor private func host(_ hostingView: NSView) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = hostingView
            hostingView.layoutSubtreeIfNeeded()
            return window
        }

        @MainActor private func waitForRequest(
            _ url: String, from provider: RecordingInlineImageProvider,
            file: StaticString = #filePath, line: UInt = #line
        ) async throws {
            for _ in 0 ..< 100 {
                if await provider.requests.contains(url) {
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let requests = await provider.requests
            XCTFail("Expected request for \(url); received \(requests)", file: file, line: line)
        }
    }

    @MainActor private final class ImageContextModel: ObservableObject {
        @Published var markdown = "before ![alt](logo.png) after"
        @Published var baseURL = URL(string: "https://example.com/first/")
    }

    private struct ImageContextView: View {
        @ObservedObject var model: ImageContextModel

        var body: some View {
            MarkdownView(self.model.markdown, imageBaseURL: self.model.baseURL)
        }
    }

    private actor RecordingInlineImageProvider: InlineImageProvider {
        private(set) var requests: [String] = []
        private(set) var labels: [String] = []

        func image(with url: URL, label: String) async throws -> Image {
            self.requests.append(url.absoluteURL.absoluteString)
            self.labels.append(label)
            return Image(systemName: "photo")
        }
    }

    private struct HashableInlineImageProvider: InlineImageProvider, Hashable {
        let tag: Int
        let recording: RecordingInlineImageProvider

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.tag == rhs.tag && lhs.recording === rhs.recording
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(self.tag)
        }

        func image(with url: URL, label: String) async throws -> Image {
            try await recording.image(with: url, label: label)
        }
    }

    private struct OtherHashableInlineImageProvider: InlineImageProvider, Hashable {
        let tag: Int

        func image(with url: URL, label: String) async throws -> Image {
            Image(systemName: "photo")
        }
    }

    private struct ValueInlineImageProvider: InlineImageProvider {
        let recording: RecordingInlineImageProvider
        func image(with url: URL, label: String) async throws -> Image {
            try await recording.image(with: url, label: label)
        }
    }
#endif
