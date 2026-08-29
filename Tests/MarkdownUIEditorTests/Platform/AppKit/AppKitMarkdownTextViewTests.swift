#if os(macOS) && canImport(AppKit)
import AppKit
@testable import MarkdownUIEditor
import XCTest

@MainActor final class MarkdownTextViewTests: XCTestCase {
    func testContextMenuFormatsSelectedTextWithoutTableActions() throws {
        for (title, expected) in [("Bold", "**hello** world\n"), ("Italic", "*hello* world\n"), ("Strikethrough", "~~hello~~ world\n")] {
            let editor = MarkdownTextView(usingTextLayoutManager: true)
            editor.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
            editor.document = MarkdownDocument(markdown: "hello world")
            let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = editor
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            window.makeFirstResponder(editor)
            editor.selectedRange = NSRange(location: 0, length: 5)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: editor.convert(NSPoint(x: 10, y: 10), to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
            let menu = try XCTUnwrap(editor.menu(for: event))
            XCTAssertNil(menu.item(withTitle: "Table"))
            let style = try XCTUnwrap(menu.item(withTitle: "Style")?.submenu)
            let action = try XCTUnwrap(style.item(withTitle: title))
            XCTAssertTrue(action.isEnabled)
            XCTAssertTrue(action.target === editor)
            XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 5))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(action.action), to: action.target, from: action))
            XCTAssertEqual(editor.document.markdown, expected)
            editor.undoManager?.undo()
            XCTAssertEqual(editor.document.markdown, "hello world\n")
        }
    }

    func testUsesTextKit2AndForwardsMultipleSelections() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        XCTAssertNotNil(textView.textLayoutManager)

        textView.document = MarkdownDocument(markdown: "first\n\nsecond")
        textView.selectedRanges = [
            NSValue(range: NSRange(location: 0, length: 1)),
            NSValue(range: NSRange(location: 7, length: 1))
        ]

        XCTAssertEqual(textView.markdownSelectedRanges, [
            NSRange(location: 0, length: 1),
            NSRange(location: 7, length: 1)
        ])
        XCTAssertTrue(textView.allowsUndo)
        XCTAssertTrue(textView.canPerform(.toggleInline(.strong)))
    }

    func testResponderActionsChangeTheDocument() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.document = MarkdownDocument(markdown: "text")
        textView.selectedRange = NSRange(location: 0, length: 4)

        textView.toggleBoldface(nil)

        XCTAssertEqual(textView.document.markdown, "**text**\n")
    }

    func testStrikethroughResponderActionChangesTheDocument() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.document = MarkdownDocument(markdown: "text")
        textView.selectedRange = NSRange(location: 0, length: 4)

        textView.toggleStrikethrough(nil)

        XCTAssertEqual(textView.document.markdown, "~~text~~\n")
    }

    func testStyleResponderActionsValidateWithoutReplacingStandardValidation() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.document = MarkdownDocument(markdown: "text")
        textView.selectedRange = NSRange(location: 0, length: 4)
        let actions = [
            #selector(MarkdownTextView.toggleBoldface(_:)),
            #selector(MarkdownTextView.toggleItalics(_:)),
            #selector(MarkdownTextView.toggleStrikethrough(_:))
        ]

        for action in actions {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            XCTAssertTrue(textView.validateUserInterfaceItem(item))
        }

        XCTAssertTrue(textView.validateUserInterfaceItem(
            NSMenuItem(title: "", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        ))
    }

    func testTaskToggleAtProjectionPositionPublishesPreservesSelectionAndRegistersUndo() throws {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let delegate = Delegate()
        window.contentView = textView
        textView.markdownDelegate = delegate
        textView.document = MarkdownDocument(markdown: "- [ ] task")
        textView.selectedRange = NSRange(location: 2, length: 0)

        XCTAssertTrue(textView.editingSession.toggleTask(atProjectionUTF16Offset: 0))
        XCTAssertEqual(textView.document.markdown, "  - [x] task\n")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 2, length: 0))
        XCTAssertEqual(delegate.documents.last?.markdown, "  - [x] task\n")

        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(textView.document.markdown, "  - [ ] task\n")
    }

    func testTaskToggleAtProjectionPositionRejectsOrdinaryListItems() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.document = MarkdownDocument(markdown: "- item")

        XCTAssertFalse(textView.editingSession.toggleTask(atProjectionUTF16Offset: 0))
        XCTAssertEqual(textView.document.markdown, "  - item\n")
    }

    func testTypingAttributesForwardThroughTheTextViewBridge() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.systemRed]

        textView.markdownTypingAttributes = attributes

        XCTAssertEqual(textView.markdownTypingAttributes[.foregroundColor] as? NSColor, NSColor.systemRed)
    }

    func testDocumentChangeReachesMarkdownDelegate() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        let delegate = Delegate()
        textView.markdownDelegate = delegate
        textView.document = MarkdownDocument(markdown: "text")
        textView.selectedRange = NSRange(location: 0, length: 4)

        textView.perform(.toggleInline(.emphasis))

        XCTAssertEqual(delegate.documents.last?.markdown, "*text*\n")
    }

    func testStructuralCommandRegistersWithTheNativeUndoManager() throws {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        textView.document = MarkdownDocument(markdown: "text")
        textView.selectedRange = NSRange(location: 0, length: 4)

        textView.toggleBoldface(nil)
        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()

        XCTAssertEqual(textView.document.markdown, "text\n")
    }

    func testNativeTypingUndoRedoRestoresDocumentProjectionAndSelection() throws {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        textView.document = MarkdownDocument(markdown: "**bold**")
        textView.selectedRange = NSRange(location: 2, length: 0)

        textView.insertText("X", replacementRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(textView.document.markdown, "**boXld**\n")
        XCTAssertEqual(textView.string, "boXld\n")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 3, length: 0))

        let undoManager = try XCTUnwrap(textView.undoManager)
        undoManager.undo()
        XCTAssertEqual(textView.document.markdown, "**bold**\n")
        XCTAssertEqual(textView.string, "bold\n")

        undoManager.redo()
        XCTAssertEqual(textView.document.markdown, "**boXld**\n")
        XCTAssertEqual(textView.string, "boXld\n")
    }

    func testReturnAtEndOfOrderedListBeforeUnorderedListCreatesOrderedItem() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.document = MarkdownDocument(markdown: """
        1. Draft the release notes
        2. Review the changes

        - Build the example apps
        - Run the snapshot tests
        """)
        let reviewRange = (textView.string as NSString).range(of: "Review the changes")
        textView.selectedRange = NSRange(location: NSMaxRange(reviewRange), length: 0)

        textView.insertNewline(nil)

        XCTAssertEqual(textView.document.blocks, [
            .list(MarkdownList(
                kind: .ordered(start: 1),
                isTight: true,
                items: [
                    MarkdownListItem(blocks: [.paragraph([.text("Draft the release notes")])]),
                    MarkdownListItem(blocks: [.paragraph([.text("Review the changes")])]),
                    MarkdownListItem(blocks: [.paragraph([])])
                ]
            )),
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [
                    MarkdownListItem(blocks: [.paragraph([.text("Build the example apps")])]),
                    MarkdownListItem(blocks: [.paragraph([.text("Run the snapshot tests")])])
                ]
            ))
        ])
        XCTAssertEqual(
            textView.string,
            "Draft the release notes\nReview the changes\n\nBuild the example apps\nRun the snapshot tests\n"
        )
    }

    func testSourceDoesNotReferenceTextKit1LayoutManager() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MarkdownUIEditor/Platform/AppKit/MarkdownTextView.swift")
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let forbidden = ["layout", "Manager"].joined()

        XCTAssertFalse(source.contains(forbidden))
    }

    func testSourceForwardsAppKitMultiRangePreEditCallbacks() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MarkdownUIEditor/Platform/AppKit/MarkdownTextView.swift")
        let source = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertTrue(source.contains("shouldChangeTextInRanges"))
        XCTAssertTrue(source.contains("replacementStrings"))
    }
}

@MainActor private final class Delegate: MarkdownTextViewDelegate {
    private(set) var documents: [MarkdownDocument] = []

    func markdownTextView(_ textView: MarkdownTextView, didChange document: MarkdownDocument) {
        documents.append(document)
    }
}
#endif
