// A Mac Catalyst test bundle has no host app, so UIKit can't create the windows these tests put an editor in.
#if os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))
    import Foundation
    @testable import MarkdownUIEditor
    import XCTest

    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    /// Each image in the editor's text is requested from the image provider once, however often the text is projected again.
    @MainActor final class MarkdownEditorImageRequestTests: XCTestCase {
        private let chart = URL(string: "https://example.com/docs/images/chart.png")!

        func testBodyImageIsRequestedOnceAfterInitialDisplay() {
            let provider = RecordingImageProvider()
            let editor = showEditor("Intro\n\n![chart](images/chart.png)\n\nOutro", provider: provider)
            waitForLoadedImages(1, in: editor)
            XCTAssertEqual(provider.requests, [chart])
        }

        func testBodyImageIsRequestedOnceAfterStructuralEditsAndUndo() throws {
            let provider = RecordingImageProvider()
            let editor = showEditor("Intro\n\n![chart](images/chart.png)\n\nOutro", provider: provider)
            waitForLoadedImages(1, in: editor)
            let undoManager = try XCTUnwrap(editor.undoManager)
            /// Tests run in one event, so each edit gets its own undo group.
            func undoGroup(_ edit: () -> Void) {
                while undoManager.groupingLevel > 0 {
                    undoManager.endUndoGrouping()
                }
                undoManager.beginUndoGrouping()
                edit()
                undoManager.endUndoGrouping()
            }

            editor.selectedRange = NSRange(location: textLength(of: editor), length: 0)
            undoGroup { pressReturn(in: editor) }
            XCTAssertEqual(editor.document.blocks.count, 4)
            assertRequestedOnce(provider, in: editor, "Return in another paragraph")

            editor.selectedRange = NSRange(location: 1, length: 0)
            undoGroup { editor.perform(.convertBlock(.heading(.two))) }
            XCTAssertEqual(editor.document.blocks.first, .heading(level: .two, content: [.text("Intro")]))
            assertRequestedOnce(provider, in: editor, "converting another block")

            for step in ["undo conversion", "undo Return"] {
                undoManager.undo()
                assertRequestedOnce(provider, in: editor, step)
            }
            XCTAssertEqual(editor.document, MarkdownDocument(markdown: "Intro\n\n![chart](images/chart.png)\n\nOutro"))
            for step in ["redo Return", "redo conversion"] {
                undoManager.redo()
                assertRequestedOnce(provider, in: editor, step)
            }
            XCTAssertEqual(editor.document.blocks.first, .heading(level: .two, content: [.text("Intro")]))
        }

        func testBodyImageIsRequestedOnceAfterTypingInItsParagraph() {
            let provider = RecordingImageProvider()
            let editor = showEditor("See ![chart](images/chart.png) here", provider: provider)
            waitForLoadedImages(1, in: editor)

            editor.selectedRange = NSRange(location: 3, length: 0)
            type(" the", in: editor)
            XCTAssertEqual(editor.document, MarkdownDocument(markdown: "See the ![chart](images/chart.png) here"))
            assertRequestedOnce(provider, in: editor, "typing before the image")
            editor.selectedRange = NSRange(location: textLength(of: editor), length: 0)
            type(" now", in: editor)
            XCTAssertEqual(editor.document, MarkdownDocument(markdown: "See the ![chart](images/chart.png) here now"))
            assertRequestedOnce(provider, in: editor, "typing after the image")
        }

        func testChangingAnImageSourceRequestsTheNewURLOnce() throws {
            let provider = RecordingImageProvider()
            let editor = showEditor("Intro\n\n![chart](images/chart.png)", provider: provider)
            waitForLoadedImages(1, in: editor)

            try XCTUnwrap(imageAttachments(in: editor).first).updateMetadata(.init(source: "images/map.png", altText: "chart"))
            XCTAssertEqual(editor.document, MarkdownDocument(markdown: "Intro\n\n![chart](images/map.png)"))
            settle(editor)
            XCTAssertEqual(provider.requests, [chart, try XCTUnwrap(URL(string: "https://example.com/docs/images/map.png"))])
        }

        func testChangingTheImageConfigurationUsesTheNewConfiguration() throws {
            let provider = RecordingImageProvider()
            let editor = showEditor("![chart](images/chart.png)\n\n| Image |\n| - |\n| ![cell](images/cell.png) |", provider: provider)
            waitForLoadedImages(2, in: editor)
            XCTAssertEqual(provider.requests.count, 2)

            let replacement = RecordingImageProvider()
            editor.imageProvider = replacement
            settle(editor)
            XCTAssertEqual(Set(replacement.requests), [chart, try XCTUnwrap(URL(string: "https://example.com/docs/images/cell.png"))])
            XCTAssertEqual(loadedImageCount(in: editor), 2)

            editor.baseURL = URL(string: "https://example.org/")
            settle(editor)
            XCTAssertEqual(
                Set(replacement.requests.dropFirst(2)),
                [try XCTUnwrap(URL(string: "https://example.org/images/chart.png")), try XCTUnwrap(URL(string: "https://example.org/images/cell.png"))]
            )

            editor.imageLoadingPolicy = .allowing(schemes: ["https"], hosts: ["images.example.com"])
            settle(editor)
            XCTAssertEqual(replacement.requests.count, 4, "Blocked images are not requested")
            XCTAssertEqual(loadedImageCount(in: editor, body: true), 0, "Blocked images show their alt text")
            XCTAssertEqual(provider.requests.count, 2)
        }

        func testTheSameURLInTwoParagraphsIsRequestedAtMostTwice() {
            let provider = RecordingImageProvider()
            let editor = showEditor("![a](images/chart.png)\n\n![b](images/chart.png)\n\nOutro", provider: provider)
            waitForLoadedImages(2, in: editor)
            editor.selectedRange = NSRange(location: textLength(of: editor), length: 0)
            pressReturn(in: editor)
            editor.selectedRange = NSRange(location: 0, length: 0)
            type("x", in: editor)
            settle(editor)
            XCTAssertEqual(Set(provider.requests), [chart])
            XCTAssertLessThanOrEqual(provider.requests.count, 2)
        }

        // MARK: - Helpers

        private func assertRequestedOnce(
            _ provider: RecordingImageProvider,
            in editor: MarkdownTextView,
            _ step: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            settle(editor)
            XCTAssertEqual(provider.requests, [chart], step, file: file, line: line)
            XCTAssertEqual(loadedImageCount(in: editor), 1, "\(step): the image stays shown", file: file, line: line)
        }

        /// Lays out the editor and gives any image request time to start.
        private func settle(_ editor: MarkdownTextView) {
            for _ in 0 ..< 5 {
                layout(editor)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            }
            layout(editor)
        }

        private func waitForLoadedImages(_ count: Int, in editor: MarkdownTextView, file: StaticString = #filePath, line: UInt = #line) {
            let deadline = Date(timeIntervalSinceNow: 2)
            while loadedImageCount(in: editor) < count, Date() < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                layout(editor)
            }
            XCTAssertEqual(loadedImageCount(in: editor), count, "Loaded images", file: file, line: line)
            settle(editor)
        }

        private func imageAttachments(in editor: MarkdownTextView) -> [MarkdownImageAttachment] {
            let storage: NSTextStorage? = editor.textStorage
            var attachments: [MarkdownImageAttachment] = []
            storage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage?.length ?? 0)) { value, _, _ in
                if let attachment = value as? MarkdownImageAttachment {
                    attachments.append(attachment)
                }
            }
            return attachments
        }

        #if os(macOS)
            private func showEditor(_ markdown: String, provider: RecordingImageProvider) -> MarkdownTextView {
                let editor = MarkdownTextView(usingTextLayoutManager: true)
                editor.imageProvider = provider
                editor.baseURL = URL(string: "https://example.com/docs/")
                editor.document = MarkdownDocument(markdown: markdown)
                editor.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
                let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = editor
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(editor)
                addTeardownBlock { @MainActor in window.orderOut(nil) }
                layout(editor)
                return editor
            }

            private func layout(_ editor: MarkdownTextView) {
                if let manager = editor.textLayoutManager {
                    manager.ensureLayout(for: manager.documentRange)
                }
                editor.layoutSubtreeIfNeeded()
            }

            private func pressReturn(in editor: MarkdownTextView) {
                editor.insertNewline(nil)
            }

            private func type(_ text: String, in editor: MarkdownTextView) {
                editor.insertText(text, replacementRange: editor.selectedRange())
            }

            private func textLength(of editor: MarkdownTextView) -> Int {
                editor.textStorage?.length ?? 0
            }

            /// Image views showing a loaded image, in the editor's text and, unless `body` is set, in its table cells.
            private func loadedImageCount(in editor: MarkdownTextView, body: Bool = false) -> Int {
                imageViews(in: editor, body: body).count { $0.image != nil }
            }

            private func imageViews(in view: NSView, body: Bool) -> [NSImageView] {
                if body, view is NSTextView, !(view is MarkdownTextView) {
                    return []
                }
                return ((view as? NSImageView).map { [$0] } ?? []) + view.subviews.flatMap { imageViews(in: $0, body: body) }
            }
        #else
            private func showEditor(_ markdown: String, provider: RecordingImageProvider) -> MarkdownTextView {
                let editor = MarkdownTextView(usingTextLayoutManager: true)
                editor.imageProvider = provider
                editor.baseURL = URL(string: "https://example.com/docs/")
                editor.document = MarkdownDocument(markdown: markdown)
                editor.frame = CGRect(x: 0, y: 0, width: 358, height: 800)
                let window = UIWindow(frame: editor.frame)
                window.rootViewController = UIViewController()
                window.rootViewController?.view.addSubview(editor)
                window.makeKeyAndVisible()
                _ = editor.becomeFirstResponder()
                addTeardownBlock { @MainActor in window.isHidden = true }
                layout(editor)
                return editor
            }

            private func layout(_ editor: MarkdownTextView) {
                if let manager = editor.textLayoutManager {
                    manager.ensureLayout(for: manager.documentRange)
                }
                editor.layoutIfNeeded()
            }

            private func pressReturn(in editor: MarkdownTextView) {
                editor.insertText("\n")
            }

            private func type(_ text: String, in editor: MarkdownTextView) {
                editor.insertText(text)
            }

            private func textLength(of editor: MarkdownTextView) -> Int {
                editor.textStorage.length
            }

            /// Image views showing a loaded image, in the editor's text and, unless `body` is set, in its table cells.
            private func loadedImageCount(in editor: MarkdownTextView, body: Bool = false) -> Int {
                imageViews(in: editor, body: body).count { $0.image != nil }
            }

            private func imageViews(in view: UIView, body: Bool) -> [UIImageView] {
                if body, view is UITextView, !(view is MarkdownTextView) {
                    return []
                }
                return ((view as? UIImageView).map { [$0] } ?? []) + view.subviews.flatMap { imageViews(in: $0, body: body) }
            }
        #endif
    }

    @MainActor private final class RecordingImageProvider: MarkdownEditorImageProvider {
        private(set) var requests: [URL] = []

        func image(for url: URL) async throws -> MarkdownEditorPlatformImage {
            requests.append(url)
            #if os(macOS)
                return NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
                    NSColor.systemBlue.setFill()
                    rect.fill()
                    return true
                }
            #else
                return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
                    UIColor.systemBlue.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
                }
            #endif
        }
    }
#endif
