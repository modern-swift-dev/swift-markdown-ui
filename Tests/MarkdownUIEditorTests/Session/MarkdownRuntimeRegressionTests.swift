#if os(macOS)
    import AppKit
    @testable import MarkdownUIEditor
    import XCTest

    @MainActor final class MarkdownRuntimeRegressionTests: XCTestCase {
        func testDeletingSeparatorIncludesDownstreamParagraph() {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.document = MarkdownDocument(markdown: "abc\n\ndef")
            view.insertText("X", replacementRange: NSRange(location: 1, length: 3))
            XCTAssertEqual(view.document.markdown, "aXdef\n")
            XCTAssertEqual(view.string, "aXdef\n")
            XCTAssertEqual(view.selectedRange, NSRange(location: 2, length: 0))
        }

        func testReturnOverParagraphSelectionCreatesParagraphs() {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.document = MarkdownDocument(markdown: "abc\n\ndef")
            view.selectedRange = NSRange(location: 1, length: 4)
            view.insertNewline(nil)
            XCTAssertEqual(view.document.blocks, [.paragraph([.text("a")]), .paragraph([.text("ef")])])
            XCTAssertEqual(view.selectedRange, NSRange(location: 2, length: 0))
        }

        func testNestedListJoinPreservesDescendants() {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.document = MarkdownDocument(markdown: "- parent\n  - first\n  - second\n    - child")
            let offset = (view.string as NSString).range(of: "second").location
            view.insertText("", replacementRange: NSRange(location: offset - 1, length: 1))
            XCTAssertEqual(MarkdownDocument(markdown: view.document.markdown), MarkdownDocument(markdown: "- parent\n  - firstsecond\n    - child"))
            XCTAssertEqual(view.selectedRange.location, offset - 1)
        }

        func testMixedBulkBoldKeepsExistingBoldWithTrailingSpace() {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.document = MarkdownDocument(blocks: [.paragraph([.strong([.text("hello")]), .text(" ")]), .paragraph([.text("world")])])
            view.selectedRange = NSRange(location: 0, length: view.string.utf16.count)
            view.perform(.toggleInline(.strong))
            XCTAssertEqual(MarkdownDocument(markdown: view.document.markdown), MarkdownDocument(markdown: "**hello** \n\n**world**"))
        }

        func testCrossParagraphEditUndoRedoKeepsVisibleAndSavedContentTogether() throws {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            view.document = MarkdownDocument(markdown: "abc\n\ndef")
            view.selectedRange = NSRange(location: 1, length: 4)
            view.insertText("X", replacementRange: view.selectedRange)
            let undo = try XCTUnwrap(view.undoManager)
            undo.undo()
            XCTAssertEqual(view.document.markdown, "abc\n\ndef\n")
            XCTAssertEqual(view.string, "abc\ndef\n")
            undo.redo()
            XCTAssertEqual(view.document.markdown, "aXef\n")
            XCTAssertEqual(view.string, "aXef\n")
            XCTAssertEqual(view.selectedRange, NSRange(location: 2, length: 0))
        }

        func testBulkNumberedListPreservesSelectionAndCreatesOneList() {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.document = MarkdownDocument(markdown: "first\n\nsecond")
            view.selectedRange = NSRange(location: 0, length: view.string.utf16.count)
            view.perform(.convertList(.ordered(start: 1)))
            XCTAssertEqual(MarkdownDocument(markdown: view.document.markdown), MarkdownDocument(markdown: "1. first\n2. second"))
            XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: view.string.utf16.count))
        }

        func testTypingAtDocumentEnd() {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.document = MarkdownDocument(markdown: "abc")
            view.selectedRange = NSRange(location: view.string.utf16.count, length: 0)
            view.insertText("X", replacementRange: view.selectedRange)
            XCTAssertTrue(view.document.markdown.contains("X"), view.document.markdown)
        }

        func testNativeCollapsedBoldTyping() {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.document = MarkdownDocument(markdown: "abc")
            view.selectedRange = NSRange(location: 2, length: 0)
            view.perform(.toggleInline(.strong))
            view.insertText("X", replacementRange: view.selectedRange)
            XCTAssertTrue(view.document.markdown.contains("**X**"), view.document.markdown)
        }

        func testCursorAfterInsertImage() {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.document = MarkdownDocument(markdown: "hello world")
            view.selectedRange = NSRange(location: 0, length: 0)
            view.perform(.insertImage(source: "image.png", title: nil, alt: "long alt"))
            XCTAssertEqual(view.selectedRange.location, 1)
        }

        func testClipboardPreservesHeading() {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.document = MarkdownDocument(markdown: "# Heading")
            view.selectedRange = NSRange(location: 0, length: 7)
            XCTAssertEqual(view.editingSession.clipboardPayload()?.markdown, "# Heading")
        }

        func testPastePreservesSingleList() {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.document = MarkdownDocument(blocks: [.paragraph([])])
            view.selectedRange = NSRange(location: 0, length: 0)
            XCTAssertTrue(view.editingSession.paste(MarkdownClipboardPayload(markdown: "- one\n- two", plainText: nil)))
            XCTAssertEqual(MarkdownDocument(markdown: view.document.markdown), MarkdownDocument(markdown: "- one\n- two"))
        }

        func testEmptyDocumentAcceptsTyping() {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.document = MarkdownDocument(markdown: "")
            view.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
            XCTAssertEqual(view.document.markdown, "hello\n")
            XCTAssertEqual(view.string, "hello\n")
        }

        func testChangeExistingLink() {
            let original = MarkdownDocument(markdown: "[hello](old)")
            let updated = MarkdownEditingEngine.apply(.setLink(destination: "new", title: nil), to: original, selection: MarkdownLogicalSelection(path: .block(0), utf16Length: 5))
            XCTAssertEqual(updated.document.blocks, [.paragraph([.link(destination: "new", title: nil, children: [.text("hello")])])])
        }

        func testPasteNewline() {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.document = MarkdownDocument(markdown: "abcd")
            view.selectedRange = NSRange(location: 2, length: 0)
            XCTAssertTrue(view.editingSession.paste(MarkdownClipboardPayload(markdown: nil, plainText: "\n")))
            XCTAssertEqual(view.document.blocks, [.paragraph([.text("ab")]), .paragraph([.text("cd")])])
            XCTAssertEqual(view.string, "ab\ncd\n")
        }

        func testCrossParagraphReplacement() {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.document = MarkdownDocument(markdown: "abc\n\ndef")
            view.insertText("X", replacementRange: NSRange(location: 1, length: 4))
            XCTAssertEqual(view.document.markdown, "aXef\n")
            XCTAssertEqual(view.string, "aXef\n")
        }

        func testSelectAllDelete() {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.document = MarkdownDocument(markdown: "abc\n\ndef")
            view.insertText("", replacementRange: NSRange(location: 0, length: view.string.utf16.count))
            XCTAssertTrue(view.document.blocks.isEmpty || view.document.blocks == [.paragraph([])])
        }

        func testMultiParagraphBold() {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.document = MarkdownDocument(markdown: "abc\n\ndef")
            view.selectedRange = NSRange(location: 0, length: 7)
            view.perform(.toggleInline(.strong))
            XCTAssertEqual(view.document.markdown, "**abc**\n\n**def**\n")
        }

        func testBoldAfterImage() {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.document = MarkdownDocument(markdown: "![long alt](image.png)hello")
            view.selectedRange = NSRange(location: 1, length: 5)
            view.perform(.toggleInline(.strong))
            XCTAssertEqual(view.document.markdown, "![long alt](image.png)**hello**\n")
        }

        func testListJoinPreservesChildList() {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.document = MarkdownDocument(markdown: "- first\n- second\n  - child")
            let offset = (view.string as NSString).range(of: "second").location
            view.insertText("", replacementRange: NSRange(location: offset - 1, length: 1))
            XCTAssertTrue(view.document.markdown.contains("child"), view.document.markdown)
        }

        func testNestedListReturn() {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.document = MarkdownDocument(markdown: "- parent\n  - child")
            let offset = NSMaxRange((view.string as NSString).range(of: "child"))
            view.selectedRange = NSRange(location: offset, length: 0)
            view.insertNewline(nil)
            guard case let .list(outer) = view.document.blocks[0], case let .list(inner) = outer.items[0].blocks[1] else {
                return XCTFail("Expected a nested list")
            }
            XCTAssertEqual(inner.items.count, 2, view.document.markdown)
        }

        func testToggleBoldWithinItalicBold() {
            let original = MarkdownDocument(blocks: [.paragraph([.emphasis([.strong([.text("hello")])])])])
            let updated = MarkdownEditingEngine.apply(.toggleInline(.strong), to: original, selection: MarkdownLogicalSelection(path: .block(0), utf16Length: 5))
            XCTAssertEqual(updated.document.blocks, [.paragraph([.emphasis([.text("hello")])])])
        }
    }
#endif
