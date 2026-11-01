@testable import MarkdownUI
import SwiftUI
import XCTest

#if os(macOS)
    import AppKit
#endif

final class ImageLoadingPolicyTests: XCTestCase {
    func testAllowAllAllowsEveryURL() throws {
        for source in ["https://example.com/a.png", "http://example.com/a.png", "file:///tmp/a.png", "data:image/png;base64,AA=="] {
            XCTAssertTrue(ImageLoadingPolicy.allowAll.allows(try XCTUnwrap(URL(string: source))), source)
        }
    }

    func testAllowingSchemesComparesCaseInsensitivelyAndAllowsAnyHostWithoutHosts() throws {
        let policy = ImageLoadingPolicy.allowing(schemes: ["HTTPS", "data"])
        XCTAssertTrue(policy.allows(try XCTUnwrap(URL(string: "https://example.com/a.png"))))
        XCTAssertTrue(policy.allows(try XCTUnwrap(URL(string: "HTTPS://other.example/a.png"))))
        XCTAssertTrue(policy.allows(try XCTUnwrap(URL(string: "data:image/png;base64,AA=="))))
        XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: "http://example.com/a.png"))))
        XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: "file:///tmp/a.png"))))
    }

    func testAllowingHostsComparesCaseInsensitivelyAndBlocksURLsWithoutAHost() throws {
        let policy = ImageLoadingPolicy.allowing(schemes: ["https", "data"], hosts: ["Images.Example.com"])
        XCTAssertTrue(policy.allows(try XCTUnwrap(URL(string: "https://images.example.com/a.png"))))
        XCTAssertTrue(policy.allows(try XCTUnwrap(URL(string: "https://IMAGES.EXAMPLE.COM/a.png"))))
        XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: "https://tracker.example.net/pixel.gif"))))
        XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: "http://images.example.com/a.png"))), "The scheme must also be allowed")
        XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: "data:image/png;base64,AA=="))))
    }

    func testPolicyDecidesOnTheResolvedURLOfRelativeSources() throws {
        let base = try XCTUnwrap(URL(string: "https://images.example.com/docs/"))
        let policy = ImageLoadingPolicy.allowing(schemes: ["https"], hosts: ["images.example.com"])
        XCTAssertTrue(policy.allows(try XCTUnwrap(URL(string: "logo.png", relativeTo: base))))
        XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: "logo.png", relativeTo: URL(string: "http://images.example.com/")))))

        let received = URLRecorder()
        _ = ImageLoadingPolicy.custom { received.append($0); return true }.allows(try XCTUnwrap(URL(string: "logo.png", relativeTo: base)))
        XCTAssertEqual(received.urls.map(\.absoluteString), ["https://images.example.com/docs/logo.png"])
        XCTAssertNil(received.urls.first?.baseURL, "Custom decisions receive the absolute URL")
    }

    func testCustomPolicyUsesItsDecision() throws {
        let policy = ImageLoadingPolicy.custom { $0.path.hasSuffix(".png") }
        XCTAssertTrue(policy.allows(try XCTUnwrap(URL(string: "https://example.com/a.png"))))
        XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: "https://example.com/a.gif"))))
    }

    func testBlockedInlineImagesAreNeverRequestedAndKeepTheirAltText() async {
        let provider = RecordingPolicyInlineImageProvider()
        let inlines: [InlineNode] = [
            .image(source: "https://images.example.com/allowed.png", children: [.text("allowed")]),
            .image(source: "https://tracker.example.net/pixel.gif", children: [.text("tracker")]),
            .image(source: "http://images.example.com/insecure.png", children: [.text("insecure")]),
            .image(source: "relative.png", children: [.text("relative")])
        ]
        let images = await InlineText.loadInlineImages(
            in: inlines,
            baseURL: URL(string: "https://images.example.com/docs/"),
            imageProvider: provider,
            imageLoadingPolicy: .allowing(schemes: ["https"], hosts: ["images.example.com"])
        )
        let requests = await provider.requests
        XCTAssertEqual(
            Set(requests),
            ["https://images.example.com/allowed.png", "https://images.example.com/docs/relative.png"]
        )
        XCTAssertEqual(Set(images.keys.map(\.alt)), ["allowed", "relative"], "Blocked images render their alt text")
    }

    func testDefaultInlinePolicyRequestsEveryImage() async {
        let provider = RecordingPolicyInlineImageProvider()
        let inlines: [InlineNode] = [
            .image(source: "https://tracker.example.net/pixel.gif", children: [.text("tracker")]),
            .image(source: "http://images.example.com/insecure.png", children: [.text("insecure")])
        ]
        let images = await InlineText.loadInlineImages(in: inlines, baseURL: nil, imageProvider: provider)
        XCTAssertEqual(images.count, 2)
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 2)
    }

    #if os(macOS)
        @MainActor func testMarkdownViewNeverRequestsBlockedBlockOrInlineImages() async throws {
            let blockRecorder = BlockURLRecorder()
            let inlineProvider = RecordingPolicyInlineImageProvider()
            let host = NSHostingView(rootView: MarkdownView(
                """
                ![block allowed](https://images.example.com/block.png)

                ![block tracker](https://tracker.example.net/block.gif)

                Text ![inline allowed](https://images.example.com/inline.png) and \
                ![inline tracker](https://tracker.example.net/inline.gif).
                """
            )
            .markdownImageProvider(RecordingBlockImageProvider(recorder: blockRecorder))
            .markdownInlineImageProvider(inlineProvider)
            .markdownImageLoadingPolicy(.allowing(schemes: ["https"], hosts: ["images.example.com"]))
            .frame(width: 400))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()

            for _ in 0 ..< 200 where await inlineProvider.requests.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            // Give a blocked request the same chance to start as the allowed one.
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()

            let inlineRequests = await inlineProvider.requests
            XCTAssertEqual(inlineRequests, ["https://images.example.com/inline.png"])
            XCTAssertEqual(Set(blockRecorder.urls.map { $0?.absoluteString }), ["https://images.example.com/block.png"])
        }
    #endif
}

private final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] {
        self.lock.withLock { self.storage }
    }

    func append(_ url: URL) {
        self.lock.withLock { self.storage.append(url) }
    }
}

private actor RecordingPolicyInlineImageProvider: InlineImageProvider {
    private(set) var requests: [String] = []

    func image(with url: URL, label: String) async throws -> Image {
        self.requests.append(url.absoluteURL.absoluteString)
        return Image(systemName: "photo")
    }
}

@MainActor private final class BlockURLRecorder {
    var urls: [URL?] = []
}

private struct RecordingBlockImageProvider: ImageProvider {
    let recorder: BlockURLRecorder

    func makeImage(url: URL?) -> some View {
        self.recorder.urls.append(url?.absoluteURL)
        return Color.gray.frame(width: 10, height: 10)
    }
}
