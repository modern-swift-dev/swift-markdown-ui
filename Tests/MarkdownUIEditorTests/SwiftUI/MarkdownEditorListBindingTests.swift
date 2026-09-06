#if canImport(SwiftUI) && (os(macOS) || os(iOS))
    @testable import MarkdownUIEditor
    import SwiftUI
    import XCTest

    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    @MainActor final class MarkdownEditorListBindingTests: XCTestCase {
        func testBlankParagraphRemainsListTargetAcrossSourceBindingRefreshes() async throws {
            for style in [MarkdownListStyle.unordered, .ordered(start: 1)] {
                let state = SourceState()
                let host = makeHost(state)
                defer { closeHost(host) }
                try await Task.sleep(for: .milliseconds(100))
                let textView = try XCTUnwrap(findEditor(in: hostView(host)))
                focus(textView, in: host)
                textView.markdownSelectedRanges = [NSRange(location: 5, length: 0)]
                insertReturn(into: textView)
                insertReturn(into: textView)
                let draft = textView.document
                let selection = textView.markdownSelectedRanges
                XCTAssertEqual(draft.blocks.prefix(3), [.paragraph([.text("Intro")]), .paragraph([]), .paragraph([])])

                for _ in 0 ..< 3 {
                    state.refresh += 1
                    textView.editingSession.onCommandStateChange?()
                    try await Task.sleep(for: .milliseconds(100))
                    XCTAssertEqual(textView.document, draft, "A view refresh must not reparse away empty editing paragraphs")
                    XCTAssertEqual(textView.markdownSelectedRanges, selection)
                }

                textView.perform(.convertList(style))
                typeText("New item", into: textView)
                try await Task.sleep(for: .milliseconds(100))
                guard textView.document.blocks.count > 3 else {
                    return XCTFail("The blank paragraphs disappeared before list conversion")
                }
                XCTAssertEqual(textView.document.blocks[3], .heading(level: .two, content: [.text("Lists")]))
                guard case let .list(list) = textView.document.blocks[2] else {
                    return XCTFail("Expected the new list in the blank paragraph before the heading")
                }
                XCTAssertEqual(list.items.first?.blocks, [.paragraph([.text("New item")])])
                XCTAssertEqual(list.kind, style == .unordered ? .unordered : .ordered(start: 1))
                XCTAssertEqual(MarkdownDocument(markdown: state.markdown), MarkdownDocument(markdown: textView.document.markdown))

                state.markdown = "# External replacement"
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(textView.document, MarkdownDocument(markdown: state.markdown), "External source changes must still reach the editor")
            }
        }

        func testSourceBindingCanRestoreAnEarlierPublishedDocument() async throws {
            let state = SourceState()
            state.markdown = "original"
            let host = makeHost(state)
            defer { closeHost(host) }
            try await Task.sleep(for: .milliseconds(100))
            let textView = try XCTUnwrap(findEditor(in: hostView(host)))
            focus(textView, in: host)
            textView.perform(.convertBlock(.heading(.one)))
            let saved = state.markdown
            XCTAssertEqual(saved, "# original\n")
            textView.perform(.convertBlock(.heading(.two)))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(state.markdown, "## original\n")

            state.markdown = saved
            try await Task.sleep(for: .milliseconds(100))

            XCTAssertEqual(textView.document, MarkdownDocument(markdown: saved))
            XCTAssertEqual(textView.document.markdown, state.markdown)
        }

        @MainActor private final class SourceState: ObservableObject {
            @Published var markdown = "Intro\n\n## Lists\n\n1. Existing"
            @Published var refresh = 0
        }

        private struct TestScreen: View {
            @ObservedObject var state: SourceState
            var body: some View {
                MarkdownEditor(markdown: $state.markdown)
                    .padding(CGFloat(state.refresh % 2))
            }
        }

        #if os(macOS)
            private typealias Host = NSWindow
            private typealias NativeView = NSView

            private func makeHost(_ state: SourceState) -> Host {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = NSHostingView(rootView: TestScreen(state: state))
                window.makeKeyAndOrderFront(nil)
                return window
            }

            private func hostView(_ host: Host) -> NativeView {
                host.contentView ?? NSView()
            }

            private func closeHost(_ host: Host) {
                host.orderOut(nil)
            }

            private func focus(_ editor: MarkdownTextView, in host: Host) {
                host.makeFirstResponder(editor)
            }

            private func insertReturn(into editor: MarkdownTextView) {
                editor.insertNewline(nil)
            }

            private func typeText(_ text: String, into editor: MarkdownTextView) {
                editor.insertText(text, replacementRange: editor.selectedRange)
            }
        #else
            private typealias Host = UIWindow
            private typealias NativeView = UIView

            private func makeHost(_ state: SourceState) -> Host {
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
                window.rootViewController = UIHostingController(rootView: TestScreen(state: state))
                window.makeKeyAndVisible()
                return window
            }

            private func hostView(_ host: Host) -> NativeView {
                host.rootViewController?.view ?? UIView()
            }

            private func closeHost(_ host: Host) {
                host.isHidden = true
            }

            private func focus(_ editor: MarkdownTextView, in host: Host) {
                _ = editor.becomeFirstResponder()
            }

            private func insertReturn(into editor: MarkdownTextView) {
                editor.insertText("\n")
            }

            private func typeText(_ text: String, into editor: MarkdownTextView) {
                editor.insertText(text)
            }
        #endif

        private func findEditor(in view: NativeView) -> MarkdownTextView? {
            if let editor = view as? MarkdownTextView {
                return editor
            }
            return view.subviews.lazy.compactMap { self.findEditor(in: $0) }.first
        }
    }
#endif
