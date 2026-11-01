@testable import MarkdownUIEditor
import SwiftUI
import XCTest

#if os(macOS) && canImport(AppKit)
    import AppKit

    @MainActor final class MarkdownTextViewReadOnlyTests: XCTestCase {
        func testReadOnlyEditorIgnoresTypingPasteAndDrop() {
            let (editor, delegate) = makeEditor("hello **world**")
            editor.isEditable = false
            editor.selectedRange = NSRange(location: 5, length: 0)

            editor.insertText("X", replacementRange: editor.selectedRange)
            editor.deleteBackward(nil)
            editor.insertNewline(nil)
            editor.selectedRange = NSRange(location: 0, length: 5)
            XCTAssertTrue(editor.editingSession.paste(MarkdownClipboardPayload(markdown: "# Pasted", plainText: "Pasted")))
            XCTAssertTrue(editor.editingSession.paste(MarkdownClipboardPayload(plainText: "plain")))
            // Dropped and pasted pasteboard contents are read through the same native path.
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("MarkdownEditorReadOnlyTests.\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.setString("dropped", forType: .string)
            XCTAssertFalse(editor.readSelection(from: pasteboard))
            XCTAssertFalse(editor.validateUserInterfaceItem(menuItem(#selector(NSText.paste(_:)))))

            XCTAssertEqual(editor.document.markdown, "hello **world**\n")
            XCTAssertEqual(editor.string, "hello world\n")
            XCTAssertTrue(delegate.documents.isEmpty)
        }

        func testReadOnlyEditorDisablesCommandsShortcutsAndContextMenu() throws {
            let (editor, delegate) = makeEditor("hello world")
            editor.isEditable = false
            editor.selectedRange = NSRange(location: 0, length: 5)
            let context = MarkdownEditorContext()
            context.setTextView(editor)

            for command in MarkdownEditorCommandState.toolbarCommands {
                XCTAssertFalse(editor.canPerform(command), "\(command)")
                XCTAssertFalse(context.canPerform(command), "\(command)")
                editor.perform(command)
                context.perform(command)
            }
            editor.toggleBoldface(nil)
            editor.toggleItalics(nil)
            editor.toggleStrikethrough(nil)
            editor.toggleUnorderedList(nil)
            editor.toggleOrderedList(nil)
            for action in [
                #selector(MarkdownTextView.toggleBoldface(_:)),
                #selector(MarkdownTextView.toggleItalics(_:)),
                #selector(MarkdownTextView.toggleStrikethrough(_:)),
                #selector(MarkdownTextView.toggleUnorderedList(_:)),
                #selector(MarkdownTextView.toggleOrderedList(_:))
            ] {
                XCTAssertFalse(editor.validateUserInterfaceItem(menuItem(action)))
            }
            let style = try XCTUnwrap(rightClickMenu(on: editor).item(withTitle: "Style")?.submenu)
            XCTAssertFalse(style.items.isEmpty)
            XCTAssertTrue(style.items.allSatisfy { !$0.isEnabled })

            XCTAssertEqual(editor.document.markdown, "hello world\n")
            XCTAssertTrue(delegate.documents.isEmpty)
        }

        func testReadOnlyEditorIgnoresCheckboxes() {
            let (editor, delegate) = makeEditor("- [ ] task")
            editor.isEditable = false

            XCTAssertFalse(editor.editingSession.toggleTask(atProjectionUTF16Offset: 0))

            XCTAssertEqual(editor.document.markdown, "  - [ ] task\n")
            XCTAssertTrue(delegate.documents.isEmpty)
        }

        func testReadOnlyTableCellsIgnoreTypingShortcutsTabAndTableMenu() throws {
            let (editor, delegate) = makeEditor("| A | B |\n| - | - |\n| a | b |")
            editor.isEditable = false
            let cells = try tableCells(in: editor)
            XCTAssertEqual(cells.count, 4)
            XCTAssertTrue(cells.allSatisfy { !$0.isEditable && $0.isSelectable })
            let last = try XCTUnwrap(cells.last)
            let window = try XCTUnwrap(editor.window)
            window.makeFirstResponder(last)
            last.setSelectedRange(NSRange(location: 0, length: 1))

            last.insertText("X", replacementRange: last.selectedRange())
            _ = last.performKeyEquivalent(with: try keyEvent("b", modifiers: .command, in: window))
            last.doCommand(by: #selector(NSResponder.insertTab(_:)))
            window.makeFirstResponder(last)
            last.setSelectedRange(NSRange(location: 0, length: 1))
            let menu = try rightClickMenu(on: last)
            for title in ["Table", "Style"] {
                let submenu = try XCTUnwrap(menu.item(withTitle: title)?.submenu, title)
                XCTAssertTrue(submenu.items.allSatisfy { !$0.isEnabled }, title)
            }

            XCTAssertEqual(last.string, "b")
            XCTAssertEqual(try tableCells(in: editor).count, 4)
            XCTAssertEqual(editor.document, MarkdownDocument(markdown: "| A | B |\n| - | - |\n| a | b |"))
            XCTAssertTrue(delegate.documents.isEmpty)
        }

        func testSwitchingEditabilityAtRuntimeTakesEffectImmediately() throws {
            let (editor, delegate) = makeEditor("text\n\n| A |\n| - |\n| a |")
            var commandStateChanges = 0
            editor.editingSession.onCommandStateChange = { commandStateChanges += 1 }
            XCTAssertTrue(try tableCells(in: editor).allSatisfy(\.isEditable))

            editor.isEditable = false
            XCTAssertGreaterThan(commandStateChanges, 0, "Toolbars refresh their enabled state")
            XCTAssertTrue(try tableCells(in: editor).allSatisfy { !$0.isEditable })
            editor.selectedRange = NSRange(location: 0, length: 4)
            XCTAssertFalse(editor.canPerform(.toggleInline(.strong)))
            // A table rendered while read-only starts read-only.
            editor.document = MarkdownDocument(markdown: "text\n\n| B |\n| - |\n| b |")
            XCTAssertTrue(try tableCells(in: editor).allSatisfy { !$0.isEditable })

            editor.isEditable = true
            XCTAssertTrue(try tableCells(in: editor).allSatisfy(\.isEditable))
            editor.selectedRange = NSRange(location: 0, length: 4)
            XCTAssertTrue(editor.canPerform(.toggleInline(.strong)))
            editor.toggleBoldface(nil)
            XCTAssertEqual(editor.document, MarkdownDocument(markdown: "**text**\n\n| B |\n| - |\n| b |"))
            let cell = try XCTUnwrap(tableCells(in: editor).last)
            editor.window?.makeFirstResponder(cell)
            cell.setSelectedRange(NSRange(location: 1, length: 0))
            cell.insertText("!", replacementRange: cell.selectedRange())
            XCTAssertEqual(editor.document, MarkdownDocument(markdown: "**text**\n\n| B |\n| - |\n| b! |"))
            XCTAssertEqual(delegate.documents.last, MarkdownDocument(markdown: "**text**\n\n| B |\n| - |\n| b! |"))
        }

        func testReadOnlyEditorStillSelectsCopiesAndKeepsLinks() {
            let (editor, _) = makeEditor("**bold** and [a link](https://example.com)")
            editor.isEditable = false

            editor.selectedRange = NSRange(location: 0, length: 4)
            XCTAssertTrue(editor.isSelectable)
            XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 4))
            XCTAssertEqual(editor.editingSession.clipboardPayload()?.markdown, "**bold**")
            XCTAssertTrue(editor.validateUserInterfaceItem(menuItem(#selector(NSText.copy(_:)))))
            let linkOffset = (editor.string as NSString).range(of: "a link").location
            XCTAssertEqual(editor.textStorage?.attribute(.link, at: linkOffset, effectiveRange: nil) as? String, "https://example.com")
        }

        func testEnvironmentModifierControlsEditability() throws {
            func editor(isEditable: Bool) -> some View {
                MarkdownEditor(document: .constant(MarkdownDocument(markdown: "text")))
                    .markdownEditorIsEditable(isEditable)
            }
            let host = NSHostingView(rootView: AnyView(editor(isEditable: false)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            let textView = try XCTUnwrap(subviews(of: MarkdownTextView.self, in: host).first)
            XCTAssertFalse(textView.isEditable)

            host.rootView = AnyView(editor(isEditable: true))
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(textView.isEditable)

            host.rootView = AnyView(MarkdownEditor(document: .constant(MarkdownDocument(markdown: "text"))))
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(textView.isEditable, "Editors are editable by default")
        }

        func testReadOnlyEditorDisablesUndoAndRedoButKeepsTheirHistory() throws {
            let (editor, _) = makeEditor("hello")
            let window = try XCTUnwrap(editor.window)
            editor.selectedRange = NSRange(location: 5, length: 0)
            editor.insertText("X", replacementRange: editor.selectedRange)
            XCTAssertEqual(editor.document.markdown, "helloX\n")

            editor.isEditable = false
            XCTAssertFalse(validateEditMenuItem(Self.undo, in: window))
            performEditMenuItem(Self.undo, in: window)
            XCTAssertEqual(editor.document.markdown, "helloX\n")

            editor.isEditable = true
            XCTAssertTrue(validateEditMenuItem(Self.undo, in: window))
            performEditMenuItem(Self.undo, in: window)
            XCTAssertEqual(editor.document.markdown, "hello\n")

            editor.isEditable = false
            XCTAssertFalse(validateEditMenuItem(Self.redo, in: window))
            performEditMenuItem(Self.redo, in: window)
            XCTAssertEqual(editor.document.markdown, "hello\n")

            editor.isEditable = true
            XCTAssertTrue(validateEditMenuItem(Self.redo, in: window))
            performEditMenuItem(Self.redo, in: window)
            XCTAssertEqual(editor.document.markdown, "helloX\n")
        }

        private static let undo = #selector(MarkdownTextView.undo(_:))
        private static let redo = #selector(MarkdownTextView.redo(_:))

        /// The responder the Edit menu sends an action to: the first one in the chain that implements it.
        private func editMenuTarget(for action: Selector, in window: NSWindow) -> NSResponder? {
            var responder = window.firstResponder
            while let current = responder, !current.responds(to: action) {
                responder = current.nextResponder
            }
            return responder
        }

        private func validateEditMenuItem(_ action: Selector, in window: NSWindow) -> Bool {
            let item = menuItem(action)
            guard let target = editMenuTarget(for: action, in: window) else {
                return false
            }
            return (target as? NSMenuItemValidation)?.validateMenuItem(item)
                ?? (target as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item)
                ?? true
        }

        private func performEditMenuItem(_ action: Selector, in window: NSWindow) {
            // A disabled menu item never sends its action.
            guard validateEditMenuItem(action, in: window) else {
                return
            }
            _ = editMenuTarget(for: action, in: window)?.perform(action, with: menuItem(action))
        }

        private func makeEditor(_ markdown: String) -> (MarkdownTextView, Delegate) {
            let editor = MarkdownTextView(usingTextLayoutManager: true)
            editor.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
            let delegate = Delegate()
            editor.markdownDelegate = delegate
            editor.document = MarkdownDocument(markdown: markdown)
            let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = editor
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(editor)
            addTeardownBlock { @MainActor in
                window.orderOut(nil)
                _ = delegate
            }
            return (editor, delegate)
        }

        private func tableCells(in editor: MarkdownTextView) throws -> [NSTextView] {
            if let manager = editor.textLayoutManager {
                manager.ensureLayout(for: manager.documentRange)
            }
            editor.layoutSubtreeIfNeeded()
            let grid = try XCTUnwrap(subviews(of: NSGridView.self, in: editor).first)
            return (0 ..< grid.numberOfRows).flatMap { row in
                (0 ..< grid.numberOfColumns).compactMap { grid.cell(atColumnIndex: $0, rowIndex: row).contentView as? NSTextView }
            }
        }

        private func rightClickMenu(on view: NSTextView) throws -> NSMenu {
            let window = try XCTUnwrap(view.window)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: view.convert(NSPoint(x: 5, y: 5), to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
            return try XCTUnwrap(view.menu(for: event))
        }

        private func keyEvent(_ key: String, modifiers: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: key,
                charactersIgnoringModifiers: key,
                isARepeat: false,
                keyCode: 11
            ))
        }

        private func menuItem(_ action: Selector) -> NSMenuItem {
            NSMenuItem(title: "", action: action, keyEquivalent: "")
        }

        private func subviews<View: NSView>(of type: View.Type, in rootView: NSView) -> [View] {
            let current = (rootView as? View).map { [$0] } ?? []
            return current + rootView.subviews.flatMap { self.subviews(of: type, in: $0) }
        }
    }

#elseif os(iOS) || targetEnvironment(macCatalyst)
    import UIKit

    @MainActor final class MarkdownTextViewReadOnlyTests: XCTestCase {
        func testReadOnlyEditorIgnoresTypingPasteAndDrop() throws {
            let (editor, delegate) = makeEditor("hello **world**")
            editor.isEditable = false
            editor.selectedRange = NSRange(location: 5, length: 0)

            editor.insertText("X")
            editor.deleteBackward()
            editor.insertText("\n")
            editor.selectedRange = NSRange(location: 0, length: 5)
            XCTAssertTrue(editor.editingSession.paste(MarkdownClipboardPayload(markdown: "# Pasted", plainText: "Pasted")))
            XCTAssertTrue(editor.editingSession.paste(MarkdownClipboardPayload(plainText: "plain")))
            XCTAssertFalse(editor.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
            // Drops and dictation replace text through UITextInput.
            let range = try XCTUnwrap(editor.textRange(from: editor.beginningOfDocument, to: editor.endOfDocument))
            editor.replace(range, withText: "dropped")

            XCTAssertEqual(editor.document.markdown, "hello **world**\n")
            XCTAssertEqual(editor.text, "hello world\n")
            XCTAssertTrue(delegate.documents.isEmpty)
        }

        func testReadOnlyEditorDisablesCommandsShortcutsAndEditMenu() throws {
            let (editor, delegate) = makeEditor("hello world")
            editor.isEditable = false
            editor.selectedRange = NSRange(location: 0, length: 5)
            let context = MarkdownEditorContext()
            context.setTextView(editor)

            for command in MarkdownEditorCommandState.toolbarCommands {
                XCTAssertFalse(editor.canPerform(command), "\(command)")
                XCTAssertFalse(context.canPerform(command), "\(command)")
                editor.perform(command)
                context.perform(command)
            }
            for command in editor.keyCommands ?? [] {
                guard let action = command.action, ["toggleStrong", "toggleEmphasis"].contains(NSStringFromSelector(action)) else {
                    continue
                }
                XCTAssertFalse(editor.canPerformAction(action, withSender: command))
                editor.perform(action, with: command)
            }
            let suggested = UIAction(title: "Copy") { _ in }
            let menu = try XCTUnwrap(editor.delegate?.textView?(editor, editMenuForTextIn: editor.selectedRange, suggestedActions: [suggested]))
            let style = try XCTUnwrap(menu.children.compactMap { $0 as? UIMenu }.first { $0.title == "Style" })
            XCTAssertTrue(style.children.compactMap { $0 as? UIAction }.allSatisfy { $0.attributes.contains(.disabled) })

            XCTAssertEqual(editor.document.markdown, "hello world\n")
            XCTAssertTrue(delegate.documents.isEmpty)
        }

        func testReadOnlyEditorIgnoresCheckboxes() {
            let (editor, delegate) = makeEditor("- [ ] task")
            editor.isEditable = false

            XCTAssertFalse(editor.editingSession.toggleTask(atProjectionUTF16Offset: 0))

            XCTAssertEqual(editor.document.markdown, "  - [ ] task\n")
            XCTAssertTrue(delegate.documents.isEmpty)
        }

        func testReadOnlyTableCellsIgnoreTypingShortcutsTabAndTableMenu() throws {
            let (editor, delegate) = makeEditor("| A | B |\n| - | - |\n| a | b |")
            editor.isEditable = false
            let cells = tableCells(in: editor)
            XCTAssertEqual(cells.count, 4)
            XCTAssertTrue(cells.allSatisfy { !$0.isEditable && $0.isSelectable })
            let last = try XCTUnwrap(cells.first { $0.text == "b" })
            last.becomeFirstResponder()
            last.selectedRange = NSRange(location: 0, length: 1)

            last.insertText("X")
            last.deleteBackward()
            last.replace(try XCTUnwrap(last.textRange(from: last.beginningOfDocument, to: last.endOfDocument)), withText: "dropped")
            for command in last.keyCommands ?? [] {
                if let action = command.action {
                    last.perform(action, with: command)
                }
            }
            let suggested = UIAction(title: "Copy") { _ in }
            let menu = try XCTUnwrap(last.delegate?.textView?(last, editMenuForTextIn: NSRange(location: 0, length: 1), suggestedActions: [suggested]))
            for title in ["Table", "Style"] {
                let submenu = try XCTUnwrap(menu.children.compactMap { $0 as? UIMenu }.first { $0.title == title }, title)
                XCTAssertTrue(submenu.children.compactMap { $0 as? UIAction }.allSatisfy { $0.attributes.contains(.disabled) }, title)
            }

            XCTAssertEqual(last.text, "b")
            XCTAssertEqual(tableCells(in: editor).count, 4)
            XCTAssertEqual(editor.document, MarkdownDocument(markdown: "| A | B |\n| - | - |\n| a | b |"))
            XCTAssertTrue(delegate.documents.isEmpty)
        }

        func testSwitchingEditabilityAtRuntimeTakesEffectImmediately() throws {
            let (editor, delegate) = makeEditor("text\n\n| A |\n| - |\n| a |")
            var commandStateChanges = 0
            editor.editingSession.onCommandStateChange = { commandStateChanges += 1 }
            XCTAssertTrue(tableCells(in: editor).allSatisfy(\.isEditable))

            editor.isEditable = false
            XCTAssertGreaterThan(commandStateChanges, 0, "Toolbars refresh their enabled state")
            XCTAssertTrue(tableCells(in: editor).allSatisfy { !$0.isEditable })
            editor.selectedRange = NSRange(location: 0, length: 4)
            XCTAssertFalse(editor.canPerform(.toggleInline(.strong)))
            // A table rendered while read-only starts read-only.
            editor.document = MarkdownDocument(markdown: "text\n\n| B |\n| - |\n| b |")
            XCTAssertTrue(tableCells(in: editor).allSatisfy { !$0.isEditable })

            editor.isEditable = true
            XCTAssertTrue(tableCells(in: editor).allSatisfy(\.isEditable))
            _ = editor.becomeFirstResponder()
            editor.selectedRange = NSRange(location: 0, length: 4)
            XCTAssertTrue(editor.canPerform(.toggleInline(.strong)))
            editor.perform(.toggleInline(.strong))
            XCTAssertEqual(editor.document, MarkdownDocument(markdown: "**text**\n\n| B |\n| - |\n| b |"))
            let cell = try XCTUnwrap(tableCells(in: editor).first { $0.text == "b" })
            cell.becomeFirstResponder()
            cell.selectedRange = NSRange(location: 1, length: 0)
            cell.insertText("!")
            XCTAssertEqual(editor.document, MarkdownDocument(markdown: "**text**\n\n| B |\n| - |\n| b! |"))
            XCTAssertEqual(delegate.documents.last, MarkdownDocument(markdown: "**text**\n\n| B |\n| - |\n| b! |"))
        }

        func testReadOnlyEditorStillSelectsCopiesAndKeepsLinks() {
            let (editor, _) = makeEditor("**bold** and [a link](https://example.com)")
            editor.isEditable = false

            editor.selectedRange = NSRange(location: 0, length: 4)
            XCTAssertTrue(editor.isSelectable)
            XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 4))
            XCTAssertEqual(editor.editingSession.clipboardPayload()?.markdown, "**bold**")
            XCTAssertTrue(editor.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
            let linkOffset = (editor.text as NSString).range(of: "a link").location
            XCTAssertEqual(editor.textStorage.attribute(.link, at: linkOffset, effectiveRange: nil) as? String, "https://example.com")
        }

        func testEnvironmentModifierControlsEditability() throws {
            func editor(isEditable: Bool) -> AnyView {
                AnyView(MarkdownEditor(document: .constant(MarkdownDocument(markdown: "text")))
                    .markdownEditorIsEditable(isEditable))
            }
            let host = UIHostingController(rootView: editor(isEditable: false))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            host.view.layoutIfNeeded()
            let textView = try XCTUnwrap(subviews(of: MarkdownTextView.self, in: host.view).first)
            XCTAssertFalse(textView.isEditable)

            host.rootView = editor(isEditable: true)
            host.view.layoutIfNeeded()
            XCTAssertTrue(textView.isEditable)

            host.rootView = AnyView(MarkdownEditor(document: .constant(MarkdownDocument(markdown: "text"))))
            host.view.layoutIfNeeded()
            XCTAssertTrue(textView.isEditable, "Editors are editable by default")
        }

        func testReadOnlyEditorHidesItsUndoHistoryFromTheSystemButKeepsIt() throws {
            let (editor, _) = makeEditor("hello")
            _ = editor.becomeFirstResponder()
            editor.selectedRange = NSRange(location: 5, length: 0)
            editor.insertText("X")
            XCTAssertEqual(editor.document.markdown, "helloX\n")

            // ⌘Z, the Edit menu, shake to undo and the shortcuts bar all go through the first
            // responder's undo manager.
            editor.isEditable = false
            XCTAssertNil(editor.undoManager)

            editor.isEditable = true
            let undoManager = try XCTUnwrap(editor.undoManager)
            XCTAssertTrue(undoManager.canUndo)
            undoManager.undo()
            XCTAssertEqual(editor.document.markdown, "hello\n")
        }

        private func makeEditor(_ markdown: String) -> (MarkdownTextView, Delegate) {
            let editor = MarkdownTextView(usingTextLayoutManager: true)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 358, height: 600))
            window.rootViewController = UIViewController()
            editor.frame = window.bounds
            window.rootViewController?.view.addSubview(editor)
            window.makeKeyAndVisible()
            let delegate = Delegate()
            editor.markdownDelegate = delegate
            editor.document = MarkdownDocument(markdown: markdown)
            addTeardownBlock { @MainActor in
                window.isHidden = true
                _ = delegate
            }
            return (editor, delegate)
        }

        private func tableCells(in editor: MarkdownTextView) -> [UITextView] {
            if let manager = editor.textLayoutManager {
                manager.ensureLayout(for: manager.documentRange)
            }
            editor.layoutIfNeeded()
            return subviews(of: UITextView.self, in: editor).filter { $0 !== editor }
        }

        private func subviews<View: UIView>(of type: View.Type, in rootView: UIView) -> [View] {
            let current = (rootView as? View).map { [$0] } ?? []
            return current + rootView.subviews.flatMap { self.subviews(of: type, in: $0) }
        }
    }
#endif

#if os(macOS) || os(iOS) || targetEnvironment(macCatalyst)
    @MainActor private final class Delegate: MarkdownTextViewDelegate {
        private(set) var documents: [MarkdownDocument] = []

        func markdownTextView(_ textView: MarkdownTextView, didChange document: MarkdownDocument) {
            documents.append(document)
        }
    }
#endif
