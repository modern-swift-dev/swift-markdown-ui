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

        func testTypingAtTheStartOfATableOrRuleLineStartsAParagraphBeforeIt() {
            for block in [Self.table, "---"] {
                for (markdown, start) in [("before\n\n" + block, 7), (block + "\n\nafter", 0)] {
                    let editor = MarkdownTextView.editing(markdown, in: self)
                    var expected = editor.document.blocks
                    let index = start == 0 ? 0 : 1
                    expected.insert(.paragraph([.text("x")]), at: index)
                    editor.selectedRange = NSRange(location: start, length: 0)

                    editor.type("x")

                    XCTAssertEqual(editor.document.blocks, expected, markdown)
                    XCTAssertEqual(editor.selectedRange, NSRange(location: start + 1, length: 0), markdown)
                    editor.assertProjectsDocument(markdown)
                }
            }
        }

        func testReturnAtTheStartOfATableOrRuleLineInsertsAnEmptyParagraphBeforeIt() {
            for block in [Self.table, "---"] {
                for (markdown, start) in [("before\n\n" + block, 7), (block + "\n\nafter", 0)] {
                    let editor = MarkdownTextView.editing(markdown, in: self)
                    var expected = editor.document.blocks
                    expected.insert(.paragraph([]), at: start == 0 ? 0 : 1)
                    editor.selectedRange = NSRange(location: start, length: 0)

                    editor.pressReturn()

                    XCTAssertEqual(editor.document.blocks, expected, markdown)
                    XCTAssertEqual(editor.selectedRange, NSRange(location: start, length: 0), markdown)
                    editor.assertProjectsDocument(markdown)
                }
            }
        }

        func testPastingAtTheStartOfATableOrRuleLineInsertsTheBlocksBeforeIt() {
            let payloads: [(MarkdownClipboardPayload, [MarkdownBlock], caretOffset: Int)] = [
                (MarkdownClipboardPayload(plainText: "plain"), [.paragraph([.text("plain")])], 5),
                (MarkdownClipboardPayload(plainText: "one\n\ntwo"), [.paragraph([.text("one")]), .paragraph([.text("two")])], 7),
                (MarkdownClipboardPayload(markdown: "**bold**", plainText: "bold"), [.paragraph([.strong([.text("bold")])])], 4),
                (
                    MarkdownClipboardPayload(markdown: "# Title\n\nbody", plainText: "Title\n\nbody"),
                    [.heading(level: .one, content: [.text("Title")]), .paragraph([.text("body")])],
                    10
                ),
                // A last block without inline text leaves the caret at the start of the table or rule.
                (MarkdownClipboardPayload(markdown: "```\ncode\n```"), [.codeBlock(info: nil, content: "code\n")], 6)
            ]
            for block in [Self.table, "---"] {
                for (markdown, start) in [("before\n\n" + block, 7), (block + "\n\nafter", 0)] {
                    for (payload, pasted, caretOffset) in payloads {
                        let editor = MarkdownTextView.editing(markdown, in: self)
                        var expected = editor.document.blocks
                        expected.insert(contentsOf: pasted, at: start == 0 ? 0 : 1)
                        editor.selectedRange = NSRange(location: start, length: 0)

                        XCTAssertTrue(editor.editingSession.paste(payload))

                        let message = "\(markdown) + \(pasted)"
                        XCTAssertEqual(editor.document.blocks, expected, message)
                        XCTAssertEqual(editor.selectedRange, NSRange(location: start + caretOffset, length: 0), message)
                        editor.assertProjectsDocument(message)
                    }
                }
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
