import MarkdownUI
import SwiftUI
import XCTest

#if os(macOS)
    import AppKit
#endif

@MainActor final class BackgroundParsingTests: XCTestCase {
    func testParsingALargeDocumentKeepsTheMainActorResponsive() async {
        let section = """
        ## Section

        Some **bold** and *italic* text with a [link](https://example.com) and `code`.

        - first item
        - second item

        """
        let markdown = String(repeating: section, count: 1_048_576 / section.utf8.count)
        let progress = ParseProgress()

        let parse = Task {
            let content = await MarkdownContent(parsing: markdown)
            progress.isFinished = true
            return content
        }
        // Each turn is a chance for the main actor to handle other work, such as user input.
        // A parse on the main actor would run to completion within a single turn.
        var mainActorTurns = 0
        while !progress.isFinished {
            mainActorTurns += 1
            await Task.yield()
        }

        XCTAssertGreaterThan(mainActorTurns, 100)
        let content = await parse.value
        XCTAssertEqual(content, MarkdownContent(markdown))
    }

    #if os(macOS)
        func testBackgroundParsingShowsThePreviousContentUntilTheNewContentIsParsed() async throws {
            let recorder = ParagraphRecorder()
            let host = NSHostingView(rootView: view(MarkdownView("**first**", parsing: .background), recorder: recorder))
            let window = Self.window(containing: host)
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(recorder.texts, [], "Nothing is shown before the first parse finishes")

            try await waitUntil(host) { recorder.lastText == "first" }

            host.rootView = view(MarkdownView("second", parsing: .background), recorder: recorder)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(recorder.lastText, "first", "The previous content stays until the new parse finishes")

            try await waitUntil(host) { recorder.lastText == "second" }
        }

        func testRapidUpdatesShowOnlyTheLatestParsedContent() async throws {
            let stale = String(repeating: "stale paragraph\n\n", count: 16384)
            let clock = ContinuousClock()
            let staleParseDuration = clock.measure { _ = MarkdownContent(stale) }
            let recorder = ParagraphRecorder()
            let host = NSHostingView(rootView: view(MarkdownView(stale, parsing: .background), recorder: recorder))
            let window = Self.window(containing: host)
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()

            host.rootView = view(MarkdownView("latest", parsing: .background), recorder: recorder)
            host.layoutSubtreeIfNeeded()
            try await waitUntil(host) { recorder.lastText == "latest" }

            // Give the cancelled parse of the stale source time to finish.
            try await Task.sleep(for: staleParseDuration * 4 + .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(recorder.lastText, "latest")
            XCTAssertFalse(recorder.texts.contains("stale paragraph"))
        }

        func testSynchronousParsingShowsTheContentOnTheFirstLayout() {
            let recorder = ParagraphRecorder()
            let mode = MarkdownView.ParsingMode.synchronous
            let host = NSHostingView(rootView: view(MarkdownView("**first**", parsing: mode), recorder: recorder))
            let window = Self.window(containing: host)
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(recorder.lastText, "first")

            host.rootView = view(MarkdownView("second", parsing: .synchronous), recorder: recorder)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(recorder.lastText, "second")
        }

        private static func window(containing view: NSView) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = view
            return window
        }

        private func view(_ markdown: MarkdownView, recorder: ParagraphRecorder) -> some View {
            markdown.markdownBlockStyle(\.paragraph) { configuration in
                recorder.record(configuration.content.renderPlainText())
                configuration.label
            }
        }

        private func waitUntil(
            _ host: NSView,
            timeout: Duration = .seconds(10),
            _ condition: () -> Bool,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let deadline = ContinuousClock.now + timeout
            while !condition() {
                guard ContinuousClock.now < deadline else {
                    XCTFail("Timed out", file: file, line: line)
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
                host.layoutSubtreeIfNeeded()
            }
        }
    #endif
}

@MainActor private final class ParseProgress {
    var isFinished = false
}

#if os(macOS)
    @MainActor private final class ParagraphRecorder {
        private(set) var texts: [String] = []

        var lastText: String? {
            self.texts.last
        }

        func record(_ text: String) -> EmptyView {
            self.texts.append(text)
            return EmptyView()
        }
    }
#endif
