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
    @Published var baseURL = URL(string: "https://example.com/first/")
}

private struct ImageContextView: View {
    @ObservedObject var model: ImageContextModel

    var body: some View {
        MarkdownView("before ![alt](logo.png) after", imageBaseURL: self.model.baseURL)
    }
}

private actor RecordingInlineImageProvider: InlineImageProvider {
    private(set) var requests: [String] = []

    func image(with url: URL, label: String) async throws -> Image {
        self.requests.append(url.absoluteURL.absoluteString)
        return Image(systemName: "photo")
    }
}
#endif
