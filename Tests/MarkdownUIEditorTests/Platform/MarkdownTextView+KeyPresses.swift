#if os(macOS) || os(iOS) || targetEnvironment(macCatalyst)
    import Foundation
    @testable import MarkdownUIEditor
    import XCTest

    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    /// Delivers key presses to a text view the way each platform's keyboard does.
    @MainActor extension MarkdownTextView {
        #if os(macOS)
            /// Creates an editor showing a document.
            static func editing(_ markdown: String, in _: XCTestCase) -> MarkdownTextView {
                let editor = MarkdownTextView(usingTextLayoutManager: true)
                editor.document = MarkdownDocument(markdown: markdown)
                return editor
            }

            var projectedText: String {
                string
            }

            func pressBackspace() {
                deleteBackward(nil)
            }

            func pressForwardDelete() {
                deleteForward(nil)
            }

            func pressReturn() {
                insertNewline(nil)
            }

            func type(_ text: String) {
                insertText(text, replacementRange: selectedRange)
            }

            /// Shows each step of an input method composition as marked text.
            func compose(_ steps: [String]) {
                for step in steps {
                    setMarkedText(
                        step,
                        selectedRange: NSRange(location: step.utf16.count, length: 0),
                        replacementRange: NSRange(location: NSNotFound, length: 0)
                    )
                }
            }

            /// Replaces the marked text with the text the input method commits.
            func commitComposition(_ text: String) {
                insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            }

            /// The range of the marked text, or nil when nothing is being composed.
            var composedRange: NSRange? {
                hasMarkedText() ? markedRange() : nil
            }
        #else
            /// Creates a first-responder editor in a window, showing a document.
            static func editing(_ markdown: String, in testCase: XCTestCase) -> MarkdownTextView {
                let editor = MarkdownTextView(usingTextLayoutManager: true)
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
                window.rootViewController = UIViewController()
                editor.frame = window.bounds
                window.rootViewController?.view.addSubview(editor)
                window.makeKeyAndVisible()
                testCase.addTeardownBlock { @MainActor in window.isHidden = true }
                editor.document = MarkdownDocument(markdown: markdown)
                XCTAssertTrue(editor.becomeFirstResponder())
                return editor
            }

            var projectedText: String {
                text
            }

            func pressBackspace() {
                deleteBackward()
            }

            /// UIKit has no public forward-delete action; hardware keyboards ask the
            /// delegate to remove the character after a collapsed caret.
            func pressForwardDelete() {
                guard selectedRange.length == 0 else {
                    deleteBackward()
                    return
                }
                let range = NSRange(location: selectedRange.location, length: 1)
                let allowed = delegate?.textView?(self, shouldChangeTextIn: range, replacementText: "") ?? true
                XCTAssertFalse(allowed, "Forward delete was expected to be handled by the editing session")
            }

            func pressReturn() {
                insertText("\n")
            }

            func type(_ text: String) {
                insertText(text)
            }

            /// Shows each step of an input method composition as marked text.
            func compose(_ steps: [String]) {
                for step in steps {
                    setMarkedText(step, selectedRange: NSRange(location: step.utf16.count, length: 0))
                }
            }

            /// Replaces the marked text with the text the input method commits.
            func commitComposition(_ text: String) {
                insertText(text)
            }

            /// The range of the marked text, or nil when nothing is being composed.
            var composedRange: NSRange? {
                markedTextRange.map { range in
                    NSRange(
                        location: offset(from: beginningOfDocument, to: range.start),
                        length: offset(from: range.start, to: range.end)
                    )
                }
            }
        #endif

        /// Cancels a composition the way deleting all of its marked text does.
        func cancelComposition() {
            compose([""])
            unmarkText()
        }

        /// Asserts that the native text is the projection of the document, without stray object characters.
        func assertProjectsDocument(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
            let expected = MarkdownProjectionBuilder().build(document: document, theme: editorTheme)
            XCTAssertEqual(projectedText, expected.attributedString.string, message, file: file, line: line)
            XCTAssertFalse(document.markdown.contains("\u{fffc}"), message, file: file, line: line)
        }
    }
#endif
