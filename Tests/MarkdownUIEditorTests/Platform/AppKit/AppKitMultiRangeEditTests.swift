#if os(macOS) && canImport(AppKit)
    import AppKit
    @testable import MarkdownUIEditor
    import XCTest

    /// AppKit applies one edit across several ranges, for example typing with a column selection.
    @MainActor final class AppKitMultiRangeEditTests: XCTestCase {
        /// Projected as "one\n\u{fffc}\ntwo\nthree\n".
        private static let markdown = "one\n\n---\n\ntwo\n\nthree"

        func testMultiRangeTypingWithRangeCrossingRuleIsRejectedAsAGroup() {
            assertGroupIsRejected(ranges: [
                NSRange(location: 0, length: 0),
                NSRange(location: 2, length: 6),
                NSRange(location: 11, length: 0)
            ])
        }

        func testMultiRangeTypingWithRangeInsideRuleIsRejectedAsAGroup() {
            assertGroupIsRejected(ranges: [
                NSRange(location: 0, length: 0),
                NSRange(location: 4, length: 1),
                NSRange(location: 11, length: 0)
            ])
        }

        func testMultiRangeTypingInsideTextBlocksAppliesEveryRange() {
            let editor = MarkdownTextView(usingTextLayoutManager: true)
            editor.document = MarkdownDocument(markdown: Self.markdown)

            type("X", in: [NSRange(location: 1, length: 0), NSRange(location: 11, length: 0)], of: editor)

            XCTAssertEqual(editor.document, MarkdownDocument(markdown: "oXne\n\n---\n\ntwo\n\ntXhree"))
            XCTAssertEqual(editor.string, "oXne\n\u{fffc}\ntwo\ntXhree\n")
        }

        func testEditRejectedWhileReconcilingRejectsItsWholeGroup() throws {
            let editor = MarkdownTextView(usingTextLayoutManager: true)
            editor.document = MarkdownDocument(markdown: Self.markdown)
            let original = editor.document
            let text = editor.string
            let ranges = [NSRange(location: 1, length: 0), NSRange(location: 11, length: 0)]
            XCTAssertTrue(editor.shouldChangeText(
                inRanges: ranges.map(NSValue.init(range:)),
                replacementStrings: ["X", "a replacement longer than the text it leaves"]
            ))
            let storage = try XCTUnwrap(editor.textStorage)

            // The second edit's text does not match its announced length, so it is rejected.
            storage.replaceCharacters(in: ranges[1], with: NSAttributedString(string: "Y", attributes: editor.typingAttributes))
            storage.replaceCharacters(in: ranges[0], with: NSAttributedString(string: "X", attributes: editor.typingAttributes))
            editor.didChangeText()

            XCTAssertEqual(editor.document, original)
            XCTAssertEqual(editor.string, text)
        }

        /// Delivers typing into several ranges the way NSTextView does for a column selection.
        private func type(_ text: String, in ranges: [NSRange], of editor: MarkdownTextView) {
            editor.selectedRanges = ranges.map(NSValue.init(range:))
            let replacements = Array(repeating: text, count: ranges.count)
            guard editor.shouldChangeText(inRanges: ranges.map(NSValue.init(range:)), replacementStrings: replacements),
                  let storage = editor.textStorage else {
                return
            }
            storage.beginEditing()
            for range in ranges.sorted(by: { $0.location > $1.location }) {
                storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: editor.typingAttributes))
            }
            storage.endEditing()
            editor.didChangeText()
        }

        private func assertGroupIsRejected(ranges: [NSRange], file: StaticString = #filePath, line: UInt = #line) {
            let editor = MarkdownTextView(usingTextLayoutManager: true)
            editor.document = MarkdownDocument(markdown: Self.markdown)
            let original = editor.document
            let text = editor.string

            type("X", in: ranges, of: editor)

            XCTAssertEqual(editor.document, original, file: file, line: line)
            XCTAssertEqual(editor.string, text, file: file, line: line)
        }
    }
#endif
