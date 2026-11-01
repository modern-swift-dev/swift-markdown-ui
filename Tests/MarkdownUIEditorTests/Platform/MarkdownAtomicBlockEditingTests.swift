#if os(macOS) || os(iOS) || targetEnvironment(macCatalyst)
    @testable import MarkdownUIEditor
    import XCTest

    /// Tables, horizontal rules and HTML blocks are atomic: key presses next to
    /// them remove the whole block or leave it unchanged.
    @MainActor final class MarkdownAtomicBlockEditingTests: XCTestCase {
        private static let table = "| A |\n| --- |\n| b |"
        private static let html = "<div>html</div>"

        func testBackspaceAfterAtomicBlockSelectsItThenDeletesIt() {
            for block in [Self.table, "---", Self.html] {
                let editor = MarkdownTextView.editing(block + "\n\nafter", in: self)
                let original = editor.document
                let paragraphStart = (editor.projectedText as NSString).range(of: "after").location
                editor.selectedRange = NSRange(location: paragraphStart, length: 0)

                editor.pressBackspace()

                XCTAssertEqual(editor.document, original, block)
                XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: paragraphStart - 1), block)
                editor.assertProjectsDocument(block)

                editor.pressBackspace()

                XCTAssertEqual(editor.document.blocks, [.paragraph([.text("after")])], block)
                XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 0), block)
                editor.assertProjectsDocument(block)
            }
        }

        func testForwardDeleteBeforeAtomicBlockSelectsItThenDeletesIt() {
            for block in [Self.table, "---"] {
                let editor = MarkdownTextView.editing("before\n\n" + block, in: self)
                let original = editor.document
                editor.selectedRange = NSRange(location: 6, length: 0)

                editor.pressForwardDelete()

                XCTAssertEqual(editor.document, original, block)
                XCTAssertEqual(editor.selectedRange, NSRange(location: 7, length: 1), block)

                editor.pressForwardDelete()

                XCTAssertEqual(editor.document.blocks, [.paragraph([.text("before")])], block)
                editor.assertProjectsDocument(block)
            }
        }

        func testTypingAfterTableOrRuleAttachmentStartsParagraph() {
            for block in [Self.table, "---"] {
                let editor = MarkdownTextView.editing(block + "\n\nafter", in: self)
                let original = editor.document
                editor.selectedRange = NSRange(location: 1, length: 0)

                editor.type("x")

                XCTAssertEqual(editor.document.blocks, [original.blocks[0], .paragraph([.text("x")]), original.blocks[1]], block)
                XCTAssertEqual(editor.selectedRange, NSRange(location: 3, length: 0), block)
                editor.assertProjectsDocument(block)
            }
        }

        func testReturnAfterTableOrRuleAttachmentStartsParagraph() {
            for block in [Self.table, "---"] {
                let editor = MarkdownTextView.editing(block + "\n\nafter", in: self)
                let original = editor.document
                editor.selectedRange = NSRange(location: 1, length: 0)

                editor.pressReturn()

                XCTAssertEqual(editor.document.blocks, [original.blocks[0], .paragraph([]), original.blocks[1]], block)
                XCTAssertEqual(editor.selectedRange, NSRange(location: 2, length: 0), block)
                editor.assertProjectsDocument(block)
            }
        }

        func testTypingAtEndOfDocumentEndingInAtomicBlockAddsParagraph() {
            for block in ["---", Self.html, Self.table] {
                let editor = MarkdownTextView.editing("before\n\n" + block, in: self)
                let original = editor.document
                let end = editor.projectedText.utf16.count
                editor.selectedRange = NSRange(location: end, length: 0)

                editor.type("y")

                XCTAssertEqual(editor.document.blocks, original.blocks + [.paragraph([.text("y")])], block)
                XCTAssertEqual(editor.selectedRange, NSRange(location: end + 1, length: 0), block)
                editor.assertProjectsDocument(block)
            }
        }

        func testReturnAtEndOfDocumentEndingInAtomicBlockAddsParagraph() {
            for block in ["---", Self.html] {
                let editor = MarkdownTextView.editing("before\n\n" + block, in: self)
                let original = editor.document
                editor.selectedRange = NSRange(location: editor.projectedText.utf16.count, length: 0)

                editor.pressReturn()

                XCTAssertEqual(editor.document.blocks, original.blocks + [.paragraph([])], block)
                editor.assertProjectsDocument(block)
            }
        }
    }
#endif
