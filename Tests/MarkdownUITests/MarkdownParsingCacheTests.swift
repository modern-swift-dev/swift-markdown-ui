@testable import MarkdownUI
import SwiftUI
import XCTest

#if os(macOS)
    import AppKit
#endif

@MainActor final class MarkdownParsingCacheTests: XCTestCase {
    func testUnchangedSourceParsesOnceAndChangesReplaceTheCachedDocument() {
        var sources: [String] = []
        let cache = MarkdownContentCache { source in
            sources.append(source)
            return MarkdownContent(source)
        }
        XCTAssertEqual(cache.content(for: "**first**").renderPlainText(), "first")
        XCTAssertEqual(cache.content(for: "**first**").renderPlainText(), "first")
        XCTAssertEqual(sources, ["**first**"])
        XCTAssertEqual(cache.content(for: "second").renderPlainText(), "second")
        XCTAssertEqual(cache.content(for: "**first**").renderPlainText(), "first")
        XCTAssertEqual(sources, ["**first**", "second", "**first**"])
    }

    func testClearingForPreparsedContentReleasesThePreviousCacheEntry() {
        var parses = 0
        let cache = MarkdownContentCache { source in
            parses += 1
            return MarkdownContent(source)
        }
        _ = cache.content(for: "first")
        cache.clear()
        _ = cache.content(for: "first")
        XCTAssertEqual(parses, 2)
    }

    func testIndependentViewCachesDoNotShareParsedDocuments() {
        var parses = 0
        let parse: (String) -> MarkdownContent = { source in
            parses += 1
            return MarkdownContent(source)
        }
        let first = MarkdownContentCache(parse: parse)
        let second = MarkdownContentCache(parse: parse)
        _ = first.content(for: "same")
        _ = second.content(for: "same")
        _ = first.content(for: "same")
        XCTAssertEqual(parses, 2)
    }

    #if os(macOS)
        func testMountedViewUpdatesAcrossStringParsedAndBuilderInitializers() async throws {
            let recorder = ParagraphRecorder()
            let host = NSHostingView(rootView: view(MarkdownView("**first**"), recorder: recorder))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(recorder.lastText, "first", "Initial rendering must be synchronous")

            let updates: [(MarkdownView, String)] = [
                (MarkdownView("**first**"), "first"),
                (MarkdownView("second"), "second"),
                (MarkdownView(MarkdownContent("preparsed")), "preparsed"),
                (MarkdownView { Paragraph { "builder" } }, "builder"),
                (MarkdownView("**first**"), "first")
            ]
            for (markdown, expected) in updates {
                host.rootView = view(markdown, recorder: recorder)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
                XCTAssertEqual(recorder.lastText, expected)
            }

            let freshRecorder = ParagraphRecorder()
            let fresh = NSHostingView(rootView: view(MarkdownView("recreated"), recorder: freshRecorder))
            window.contentView = fresh
            fresh.layoutSubtreeIfNeeded()
            XCTAssertEqual(freshRecorder.lastText, "recreated")
        }

        private func view(_ markdown: MarkdownView, recorder: ParagraphRecorder) -> some View {
            markdown.markdownBlockStyle(\.paragraph) { configuration in
                recorder.record(configuration.content.renderPlainText())
                configuration.label
            }
        }
    #endif
}

#if os(macOS)
    @MainActor private final class ParagraphRecorder {
        var lastText: String?

        func record(_ text: String) -> EmptyView {
            self.lastText = text
            return EmptyView()
        }
    }
#endif
