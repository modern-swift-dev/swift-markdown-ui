#if os(macOS) || os(iOS) || targetEnvironment(macCatalyst)
    @testable import MarkdownUIEditor
    import XCTest

    /// Code blocks are text containers: edits inside them stay inside, and edits
    /// at their edges never change their kind.
    @MainActor final class MarkdownCodeBlockEditingTests: XCTestCase {
        private static let code = MarkdownBlock.codeBlock(info: nil, content: "code\n")

        func testBackspaceAtCodeBlockStartRemovesEmptyParagraphBeforeIt() {
            let editor = MarkdownTextView.editing("", in: self)
            editor.document = MarkdownDocument(blocks: [.paragraph([]), Self.code])
            editor.selectedRange = NSRange(location: 1, length: 0)

            editor.pressBackspace()

            XCTAssertEqual(editor.document.blocks, [Self.code])
            XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 0))
            editor.assertProjectsDocument("empty paragraph before code")
        }

        func testBackspaceAtCodeBlockStartAfterTextOnlyMovesTheCaret() {
            let editor = MarkdownTextView.editing("text\n\n```\ncode\n```", in: self)
            let original = editor.document
            editor.selectedRange = NSRange(location: 5, length: 0)

            editor.pressBackspace()

            XCTAssertEqual(editor.document, original)
            XCTAssertEqual(editor.selectedRange, NSRange(location: 4, length: 0))
            editor.assertProjectsDocument("text before code")
        }

        func testBackspaceAfterCodeBlockRemovesEmptyParagraphOrMovesTheCaret() {
            let editor = MarkdownTextView.editing("", in: self)
            editor.document = MarkdownDocument(blocks: [Self.code, .paragraph([]), .paragraph([.text("after")])])
            let emptyStart = "code\n\n".utf16.count
            editor.selectedRange = NSRange(location: emptyStart, length: 0)

            editor.pressBackspace()

            XCTAssertEqual(editor.document.blocks, [Self.code, .paragraph([.text("after")])])
            XCTAssertEqual(editor.selectedRange, NSRange(location: emptyStart - 1, length: 0))

            editor.selectedRange = NSRange(location: emptyStart, length: 0)
            editor.pressBackspace()

            XCTAssertEqual(editor.document.blocks, [Self.code, .paragraph([.text("after")])])
            XCTAssertEqual(editor.selectedRange, NSRange(location: emptyStart - 1, length: 0))
            editor.assertProjectsDocument("paragraph after code")
        }

        func testForwardDeleteBeforeCodeBlockRemovesEmptyParagraph() {
            let editor = MarkdownTextView.editing("", in: self)
            editor.document = MarkdownDocument(blocks: [.paragraph([.text("text")]), .paragraph([]), Self.code])
            editor.selectedRange = NSRange(location: 5, length: 0)

            editor.pressForwardDelete()

            XCTAssertEqual(editor.document.blocks, [.paragraph([.text("text")]), Self.code])
            editor.assertProjectsDocument("forward delete before code")
        }

        func testPastingCodeCopiedFromCodeBlockInsertsPlainTextInSameBlock() throws {
            let editor = MarkdownTextView.editing("```swift\nlet value = 1\n```", in: self)
            editor.selectedRange = NSRange(location: 4, length: 5)
            let payload = try XCTUnwrap(editor.editingSession.clipboardPayload())
            XCTAssertEqual(payload.plainText, "value")

            editor.selectedRange = NSRange(location: 13, length: 0)
            XCTAssertTrue(editor.editingSession.paste(payload))

            XCTAssertEqual(editor.document.blocks, [.codeBlock(info: "swift", content: "let value = 1value\n")])
            XCTAssertEqual(editor.selectedRange, NSRange(location: 18, length: 0))
            editor.assertProjectsDocument("paste in code")
        }

        func testReturnTwiceAtEndOfLastCodeBlockStartsParagraph() {
            let editor = MarkdownTextView.editing("before\n\n```\ncode\n```", in: self)
            let codeEnd = "before\ncode".utf16.count
            editor.selectedRange = NSRange(location: codeEnd, length: 0)

            editor.pressReturn()

            XCTAssertEqual(editor.document.blocks, [.paragraph([.text("before")]), .codeBlock(info: nil, content: "code\n\n")])

            editor.pressReturn()

            XCTAssertEqual(editor.document.blocks, [.paragraph([.text("before")]), Self.code, .paragraph([])])
            XCTAssertEqual(editor.selectedRange, NSRange(location: codeEnd + 2, length: 0))
            editor.type("x")
            XCTAssertEqual(editor.document.blocks, [.paragraph([.text("before")]), Self.code, .paragraph([.text("x")])])
            editor.assertProjectsDocument("leave code block")
        }

        func testTypingAtEndOfDocumentEndingInParagraphAppendsToIt() {
            for markdown in ["last", "```\ncode\n```\n\nlast"] {
                let editor = MarkdownTextView.editing(markdown, in: self)
                let original = editor.document
                let end = editor.projectedText.utf16.count
                editor.selectedRange = NSRange(location: end, length: 0)

                editor.type("x")

                XCTAssertEqual(editor.document.blocks, original.blocks.dropLast() + [.paragraph([.text("lastx")])], markdown)
                XCTAssertEqual(editor.selectedRange, NSRange(location: end, length: 0), markdown)
                editor.assertProjectsDocument(markdown)
            }
        }

        func testSelectionAcrossCodeBlockEdgeKeepsBothKinds() {
            let editor = MarkdownTextView.editing("text\n\n```\ncode\n```", in: self)
            editor.selectedRange = NSRange(location: 2, length: 5)

            editor.type("X")

            XCTAssertEqual(editor.document.blocks, [.paragraph([.text("teX")]), .codeBlock(info: nil, content: "de\n")])
            editor.assertProjectsDocument("selection across code edge")
        }
    }
#endif
