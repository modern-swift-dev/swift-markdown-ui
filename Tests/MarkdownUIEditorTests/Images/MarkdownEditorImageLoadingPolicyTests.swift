import Foundation
@testable import MarkdownUIEditor
import XCTest

#if canImport(AppKit)
    import AppKit
    import SwiftUI
#elseif canImport(UIKit)
    import UIKit
#endif

@MainActor final class MarkdownEditorImageLoadingPolicyTests: XCTestCase {
    func testAllowAllAllowsEveryURL() throws {
        for source in ["https://example.com/a.png", "http://example.com/a.png", "file:///tmp/a.png", "data:image/png;base64,AA=="] {
            XCTAssertTrue(MarkdownEditorImageLoadingPolicy.allowAll.allows(try XCTUnwrap(URL(string: source))), source)
        }
    }

    func testAllowingSchemesComparesCaseInsensitivelyAndAllowsAnyHostWithoutHosts() throws {
        let policy = MarkdownEditorImageLoadingPolicy.allowing(schemes: ["HTTPS", "data"])
        XCTAssertTrue(policy.allows(try XCTUnwrap(URL(string: "https://example.com/a.png"))))
        XCTAssertTrue(policy.allows(try XCTUnwrap(URL(string: "HTTPS://other.example/a.png"))))
        XCTAssertTrue(policy.allows(try XCTUnwrap(URL(string: "data:image/png;base64,AA=="))))
        XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: "http://example.com/a.png"))))
        XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: "file:///tmp/a.png"))))
    }

    func testAllowingHostsComparesCaseInsensitivelyAndBlocksURLsWithoutAHost() throws {
        let policy = MarkdownEditorImageLoadingPolicy.allowing(schemes: ["https", "data"], hosts: ["Images.Example.com"])
        XCTAssertTrue(policy.allows(try XCTUnwrap(URL(string: "https://images.example.com/a.png"))))
        XCTAssertTrue(policy.allows(try XCTUnwrap(URL(string: "https://IMAGES.EXAMPLE.COM/a.png"))))
        XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: "https://tracker.example.net/pixel.gif"))))
        XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: "http://images.example.com/a.png"))), "The scheme must also be allowed")
        XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: "data:image/png;base64,AA=="))))
    }

    func testCustomPolicyReceivesTheResolvedAbsoluteURL() throws {
        let received = URLRecorder()
        let policy = MarkdownEditorImageLoadingPolicy.custom { url in
            received.append(url)
            return url.path.hasSuffix(".png")
        }
        let base = try XCTUnwrap(URL(string: "https://images.example.com/docs/"))
        XCTAssertTrue(policy.allows(try XCTUnwrap(URL(string: "logo.png", relativeTo: base))))
        XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: "https://example.com/a.gif"))))
        XCTAssertEqual(received.urls.map(\.absoluteString), ["https://images.example.com/docs/logo.png", "https://example.com/a.gif"])
        XCTAssertNil(received.urls.first?.baseURL)
    }

    func testBlockedEditorImagesAreNeverRequestedAndShowTheirAltText() async throws {
        let provider = RecordingPolicyImageProvider()
        let session = MarkdownEditingSession(
            document: MarkdownDocument(markdown: """
            ![allowed](https://images.example.com/allowed.png) ![tracker](https://tracker.example.net/pixel.gif)

            ![insecure](http://images.example.com/insecure.png) ![relative](relative.png)
            """),
            baseURL: URL(string: "https://images.example.com/docs/"),
            imageProvider: provider,
            imageLoadingPolicy: .allowing(schemes: ["https"], hosts: ["images.example.com"])
        )
        let views = try imageViews(in: session.projection.attributedString)
        XCTAssertEqual(Set(views.keys), ["allowed", "tracker", "insecure", "relative"])

        try await wait { provider.requests.count == 2 }
        // Give a blocked request the same chance to start as the allowed ones.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            Set(provider.requests),
            ["https://images.example.com/allowed.png", "https://images.example.com/docs/relative.png"]
        )
        XCTAssertEqual(visibleAltText(in: try XCTUnwrap(views["tracker"])), "tracker")
        XCTAssertEqual(visibleAltText(in: try XCTUnwrap(views["insecure"])), "insecure")
        XCTAssertNil(visibleAltText(in: try XCTUnwrap(views["allowed"])), "Loaded images hide their alt text")
    }

    func testDefaultPolicyRequestsEveryEditorImage() async throws {
        let provider = RecordingPolicyImageProvider()
        let session = MarkdownEditingSession(
            document: MarkdownDocument(markdown: "![a](http://tracker.example.net/a.gif) ![b](https://example.com/b.png)"),
            imageProvider: provider
        )
        _ = try imageViews(in: session.projection.attributedString)
        try await wait { provider.requests.count == 2 }
    }

    #if os(macOS)
        func testSwiftUIModifierSetsTheEditorPolicy() throws {
            let host = NSHostingView(rootView: MarkdownEditor(document: .constant(MarkdownDocument(markdown: "text")))
                .markdownEditorImageLoadingPolicy(.allowing(schemes: ["https"]))
                .markdownEditorShowsFormattingToolbar(false))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            let textView = try XCTUnwrap(findTextView(in: host))
            let policy = textView.editingSession.imageLoadingPolicy
            XCTAssertTrue(policy.allows(try XCTUnwrap(URL(string: "https://example.com/a.png"))))
            XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: "http://example.com/a.png"))))
        }

        private func findTextView(in view: NSView) -> MarkdownTextView? {
            if let textView = view as? MarkdownTextView {
                return textView
            }
            return view.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
        }
    #endif

    // MARK: - Helpers

    #if canImport(AppKit)
        private typealias PlatformView = NSView
    #elseif canImport(UIKit)
        private typealias PlatformView = UIView
    #endif

    /// Loads the native view of every image attachment, keyed by alt text.
    private func imageViews(in text: NSAttributedString) throws -> [String: PlatformView] {
        let storage = NSTextContentStorage()
        var views: [String: PlatformView] = [:]
        var failure: Error?
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let attachment = value as? MarkdownImageAttachment else {
                return
            }
            do {
                let viewProvider = try XCTUnwrap(attachment.viewProvider(
                    for: nil, location: storage.documentRange.location, textContainer: nil
                ))
                views[attachment.metadata.altText] = try XCTUnwrap(viewProvider.view)
                retained.append(viewProvider)
            } catch {
                failure = error
            }
        }
        if let failure {
            throw failure
        }
        return views
    }

    private var retained: [AnyObject] = []

    private func visibleAltText(in view: PlatformView) -> String? {
        for subview in view.subviews where !subview.isHidden {
            #if canImport(AppKit)
                if let label = subview as? NSTextField {
                    return label.stringValue
                }
            #elseif canImport(UIKit)
                if let label = subview as? UILabel {
                    return label.text
                }
            #endif
        }
        return nil
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for image requests")
    }
}

private final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] {
        lock.withLock { storage }
    }

    func append(_ url: URL) {
        lock.withLock { storage.append(url) }
    }
}

@MainActor private final class RecordingPolicyImageProvider: MarkdownEditorImageProvider {
    private(set) var requests: [String] = []

    func image(for url: URL) async throws -> MarkdownEditorPlatformImage {
        requests.append(url.absoluteString)
        #if canImport(AppKit)
            return NSImage(size: NSSize(width: 4, height: 4))
        #else
            return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        #endif
    }
}
