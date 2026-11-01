@testable import MarkdownUI
import SwiftUI
import XCTest

@MainActor final class HeadingAnchorTests: XCTestCase {
    func testHeadingIdentifiersMatchTheSharedGitHubCorpus() throws {
        var slugger = HeadingSlugger()
        for entry in try HeadingIdentifierCorpus.load() {
            XCTAssertEqual(slugger.identifier(for: entry.input), entry.expected, entry.name)
        }
    }

    func testDuplicateHeadingsGetNumberedIdentifiersInDocumentOrder() {
        let content = MarkdownContent(
            """
            # Hello, World!

            > ## Hello, World!

            - ### Hello, World!

            #### Hello, *World*!
            """
        )

        let headings = HeadingIdentifiers(content.blocks)

        XCTAssertEqual(headings.identifiers, ["hello-world", "hello-world-1", "hello-world-2", "hello-world-3"])
        XCTAssertEqual(headings.blocks.headingIdentifiers, ["hello-world", "hello-world-1", "hello-world-2", "hello-world-3"])
    }
}

/// Reads the corpus shared with the editor tests, so both modules stay on one algorithm.
///
/// The cases are github-slugger's fixtures, which were generated from GitHub's rendered
/// heading anchors (https://github.com/Flet/github-slugger, `test/fixtures.json`). The
/// "Unassigned" fixture is left out: Swift's newer Unicode tables assign some of its
/// code points, which Unicode 13 left unassigned.
enum HeadingIdentifierCorpus {
    struct Entry: Decodable {
        let name: String
        let input: String
        let expected: String
    }

    static func load() throws -> [Entry] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HeadingIdentifierCorpus.json")
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
    }
}

private extension [BlockNode] {
    var headingIdentifiers: [String?] {
        flatMap { block -> [String?] in
            if case let .heading(_, _, identifier) = block {
                return [identifier]
            }
            return block.children.headingIdentifiers
        }
    }
}

#if os(macOS)
    import AppKit

    @MainActor final class HeadingFragmentLinkTests: XCTestCase {
        private static let document = (["[Jump](#hello-world) [Elsewhere](#missing)"] + (0 ..< 30).map { "Paragraph \($0)" } + ["## Hello, World!"])
            .joined(separator: "\n\n")

        func testFragmentLinkScrollsToItsHeadingInsideAScrollView() async throws {
            let opened = OpenedURLs()
            let probe = OpenURLProbe()
            let host = self.host(ScrollView { self.markdown(probe) }, opened: opened)
            defer { host.window?.close() }
            try await Task.sleep(for: .milliseconds(50))
            let scrollView = try XCTUnwrap(host.firstSubview(of: NSScrollView.self))
            XCTAssertEqual(scrollView.contentView.bounds.minY, 0)

            try XCTUnwrap(probe.action)(try XCTUnwrap(URL(string: "#hello-world")))
            try await Task.sleep(for: .milliseconds(50))

            XCTAssertGreaterThan(scrollView.contentView.bounds.minY, 0)
            XCTAssertEqual(opened.urls, [])
        }

        func testUnmatchedFragmentLinkGoesToTheOpenURLAction() async throws {
            let opened = OpenedURLs()
            let probe = OpenURLProbe()
            let host = self.host(ScrollView { self.markdown(probe) }, opened: opened)
            defer { host.window?.close() }
            try await Task.sleep(for: .milliseconds(50))

            try XCTUnwrap(probe.action)(try XCTUnwrap(URL(string: "#missing")))

            XCTAssertEqual(opened.urls, [URL(string: "#missing")])
        }

        func testFragmentLinkOutsideAScrollViewGoesToTheOpenURLAction() async throws {
            let opened = OpenedURLs()
            let probe = OpenURLProbe()
            let host = self.host(VStack { self.markdown(probe) }, opened: opened)
            defer { host.window?.close() }
            try await Task.sleep(for: .milliseconds(50))

            try XCTUnwrap(probe.action)(try XCTUnwrap(URL(string: "#hello-world")))

            XCTAssertEqual(opened.urls, [URL(string: "#hello-world")])
        }

        private func markdown(_ probe: OpenURLProbe) -> some View {
            MarkdownView(Self.document)
                .markdownBlockStyle(\.paragraph) { configuration in
                    configuration.label.frame(height: 40).background(OpenURLProbeView(probe: probe))
                }
        }

        private func host(_ view: some View, opened: OpenedURLs) -> NSView {
            let hosted = NSHostingView(
                rootView: view
                    .frame(width: 300, height: 200)
                    .environment(\.openURL, OpenURLAction { url in
                        opened.urls.append(url)
                        return .handled
                    })
            )
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosted
            // Scroll views apply programmatic scrolling only while their window is on screen.
            window.orderFront(nil)
            hosted.layoutSubtreeIfNeeded()
            return hosted
        }
    }

    @MainActor private final class OpenedURLs {
        var urls: [URL] = []
    }

    @MainActor private final class OpenURLProbe {
        var action: OpenURLAction?
    }

    /// Captures the open-URL action that links inside the Markdown view use.
    private struct OpenURLProbeView: View {
        @Environment(\.openURL) private var openURL
        let probe: OpenURLProbe

        var body: some View {
            self.probe.action = self.openURL
            return Color.clear
        }
    }

    private extension NSView {
        func firstSubview<View: NSView>(of type: View.Type) -> View? {
            for subview in self.subviews {
                if let match = subview as? View ?? subview.firstSubview(of: type) {
                    return match
                }
            }
            return nil
        }
    }
#endif
