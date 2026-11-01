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

        func testPastingBlankTextAtTheStartOfATableOrRuleLineChangesNothing() {
            for block in [Self.table, "---"] {
                for payload in [MarkdownClipboardPayload(markdown: " \n\n"), MarkdownClipboardPayload(plainText: "\n \n")] {
                    let editor = MarkdownTextView.editing(block + "\n\nafter", in: self)
                    let original = editor.document
                    editor.selectedRange = NSRange(location: 0, length: 0)

                    XCTAssertTrue(editor.editingSession.paste(payload))

                    XCTAssertEqual(editor.document, original, block)
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

        /// Documents and carets where typed text starts a paragraph, with the index of that paragraph.
        private static var paragraphStartingCarets: [(markdown: String, caret: (String) -> Int, index: Int)] {
            [table, "---"].flatMap { block -> [(markdown: String, caret: (String) -> Int, index: Int)] in
                [
                    (block + "\n\nafter", { _ in 1 }, 1),
                    (block + "\n\nafter", { _ in 0 }, 0),
                    ("before\n\n" + block, { _ in 7 }, 1)
                ]
            } + [table, "---", html].map { block in
                ("before\n\n" + block, { $0.utf16.count }, 2)
            }
        }

        func testComposingWhereTypedTextStartsAParagraphShowsAndCommitsTheTextThere() {
            for (markdown, caret, index) in Self.paragraphStartingCarets {
                let editor = MarkdownTextView.editing(markdown, in: self)
                let start = caret(editor.projectedText)
                let message = "\(markdown) at \(start)"
                var expected = editor.document.blocks
                expected.insert(.paragraph([.text("你好")]), at: index)
                editor.selectedRange = NSRange(location: start, length: 0)

                editor.compose(["n", "ni"])

                guard let marked = editor.composedRange else {
                    XCTFail("The composition should be in progress: \(message)")
                    continue
                }
                // The marked text is on a line of its own, not on the table's or rule's line.
                let text = editor.projectedText as NSString
                XCTAssertEqual(text.substring(with: marked), "ni", message)
                XCTAssertTrue(marked.location == 0 || text.substring(with: NSRange(location: marked.location - 1, length: 1)) == "\n", message)
                XCTAssertEqual(text.substring(with: NSRange(location: NSMaxRange(marked), length: 1)), "\n", message)

                editor.commitComposition("你好")

                XCTAssertNil(editor.composedRange, message)
                XCTAssertEqual(editor.document.blocks, expected, message)
                XCTAssertEqual(editor.selectedRange, NSRange(location: marked.location + 2, length: 0), message)
                editor.assertProjectsDocument(message)
            }
        }

        func testCancellingACompositionWhereTypedTextStartsAParagraphChangesNothing() {
            for (markdown, caret, _) in Self.paragraphStartingCarets {
                let editor = MarkdownTextView.editing(markdown, in: self)
                let original = editor.document
                let originalText = editor.projectedText
                let start = caret(originalText)
                let message = "\(markdown) at \(start)"
                editor.selectedRange = NSRange(location: start, length: 0)

                editor.compose(["n", "ni"])
                editor.cancelComposition()

                XCTAssertNil(editor.composedRange, message)
                XCTAssertEqual(editor.document, original, message)
                XCTAssertEqual(editor.projectedText, originalText, message)
            }
        }

        func testOneUndoRemovesTheParagraphACompositionStarted() throws {
            for (markdown, caret, _) in Self.paragraphStartingCarets {
                let editor = MarkdownTextView.editing(markdown, in: self)
                #if os(macOS)
                    // An AppKit text view gets its undo manager from its window.
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
                    window.contentView = editor
                    defer { window.contentView = nil }
                #endif
                let original = editor.document
                let start = caret(editor.projectedText)
                let message = "\(markdown) at \(start)"
                editor.selectedRange = NSRange(location: start, length: 0)
                let undoManager = try XCTUnwrap(editor.undoManager)
                undoManager.groupsByEvent = false
                defer { undoManager.groupsByEvent = true }
                /// Each input method step is a separate event, with its own undo group.
                func event(_ action: () -> Void) {
                    undoManager.beginUndoGrouping()
                    action()
                    undoManager.endUndoGrouping()
                }

                event { editor.compose(["n"]) }
                event { editor.compose(["ni"]) }
                event { editor.commitComposition("你好") }
                XCTAssertNotEqual(editor.document, original, message)

                undoManager.undo()

                XCTAssertEqual(editor.document, original, message)
                editor.assertProjectsDocument(message)
                undoManager.removeAllActions()
            }
        }

        func testCommittingACompositionWithUnmarkTextEndsItAtOnce() throws {
            let editor = MarkdownTextView.editing("---\n\nafter", in: self)
            #if os(macOS)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = editor
                window.makeFirstResponder(editor)
                defer { window.contentView = nil }
            #endif
            let undoManager = try XCTUnwrap(editor.undoManager)
            editor.selectedRange = NSRange(location: 1, length: 0)

            editor.compose(["ni"])
            editor.unmarkText()

            XCTAssertNil(editor.composedRange)
            XCTAssertTrue(undoManager.isUndoRegistrationEnabled)
            XCTAssertEqual(editor.document.blocks[1], .paragraph([.text("ni")]))
            undoManager.removeAllActions()
        }

        func testLeavingTheWindowMidCompositionRecordsUndoAgain() throws {
            let editor = MarkdownTextView.editing("---\n\nafter", in: self)
            #if os(macOS)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = editor
                window.makeFirstResponder(editor)
            #endif
            let undoManager = try XCTUnwrap(editor.undoManager)
            editor.selectedRange = NSRange(location: 1, length: 0)

            editor.compose(["ni"])
            #if os(macOS)
                window.contentView = nil
            #else
                editor.removeFromSuperview()
            #endif

            XCTAssertTrue(undoManager.isUndoRegistrationEnabled)
            undoManager.removeAllActions()
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
