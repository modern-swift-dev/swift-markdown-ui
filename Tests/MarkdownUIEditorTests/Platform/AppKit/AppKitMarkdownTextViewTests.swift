#if os(macOS) && canImport(AppKit)
    import AppKit
    @testable import MarkdownUIEditor
    import XCTest

    @MainActor final class MarkdownTextViewTests: XCTestCase {
        func testDetachedEditorIgnoresUnrelatedUndoNotifications() {
            let editor = MarkdownTextView(usingTextLayoutManager: true)
            editor.document = MarkdownDocument(markdown: "text")
            XCTAssertNil(editor.undoManager)
            var updates = 0
            editor.editingSession.onCommandStateChange = { updates += 1 }

            NotificationCenter.default.post(name: .NSUndoManagerDidUndoChange, object: UndoManager())
            NotificationCenter.default.post(name: .NSUndoManagerDidRedoChange, object: UndoManager())

            XCTAssertEqual(updates, 0)
        }

        func testUndoNotificationsFollowCurrentWindowManager() throws {
            let editor = MarkdownTextView(usingTextLayoutManager: true)
            let frame = NSRect(x: 0, y: 0, width: 400, height: 200)
            let firstWindow = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            let secondWindow = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            firstWindow.contentView = editor
            firstWindow.makeFirstResponder(editor)
            editor.document = MarkdownDocument(markdown: "text")
            defer {
                firstWindow.contentView = nil
                secondWindow.contentView = nil
            }
            let firstManager = try XCTUnwrap(editor.undoManager)
            var updates = 0
            editor.editingSession.onCommandStateChange = { updates += 1 }
            NotificationCenter.default.post(name: .NSUndoManagerDidUndoChange, object: firstManager)
            XCTAssertGreaterThan(updates, 0)

            firstWindow.contentView = nil
            secondWindow.contentView = editor
            secondWindow.makeFirstResponder(editor)
            let secondManager = try XCTUnwrap(editor.undoManager)
            XCTAssertFalse(firstManager === secondManager)
            updates = 0
            NotificationCenter.default.post(name: .NSUndoManagerDidUndoChange, object: firstManager)
            XCTAssertEqual(updates, 0)
            NotificationCenter.default.post(name: .NSUndoManagerDidRedoChange, object: secondManager)
            XCTAssertGreaterThan(updates, 0)
        }

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

        func testClickingAHeadingFragmentLinkScrollsToTheHeading() async throws {
            let frame = NSRect(x: 0, y: 0, width: 400, height: 220)
            let scrollView = NSScrollView(frame: frame)
            let editor = MarkdownTextView(usingTextLayoutManager: true)
            editor.frame = frame
            editor.isVerticallyResizable = true
            editor.maxSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
            editor.textContainer?.widthTracksTextView = true
            scrollView.documentView = editor
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = scrollView
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            let paragraphs = (0 ..< 80).map { "Paragraph \($0)" }
            editor.document = MarkdownDocument(markdown: (["[Jump](#hello-world)"] + paragraphs + ["## Hello, World!"]).joined(separator: "\n\n"))
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(scrollView.contentView.bounds.minY, 0)

            XCTAssertEqual(editor.delegate?.textView?(editor, clickedOnLink: "#missing", at: 0), false)
            XCTAssertEqual(scrollView.contentView.bounds.minY, 0)
            XCTAssertEqual(editor.delegate?.textView?(editor, clickedOnLink: "https://example.com", at: 0), false)
            XCTAssertEqual(editor.delegate?.textView?(editor, clickedOnLink: "#hello-world", at: 0), true)

            let heading = try XCTUnwrap(editor.editingSession.headingProjectionRange(forLinkDestination: "#hello-world"))
            var actualRange = NSRange()
            let headingRect = editor.convert(
                window.convertFromScreen(editor.firstRect(forCharacterRange: heading, actualRange: &actualRange)),
                from: nil
            )
            XCTAssertGreaterThan(scrollView.contentView.bounds.minY, 0)
            XCTAssertTrue(editor.visibleRect.intersects(headingRect))
        }

        func testTaskCheckboxLayersFollowScrolledViewportAfterTyping() async throws {
            let frame = NSRect(x: 0, y: 0, width: 400, height: 220)
            let scrollView = NSScrollView(frame: frame)
            scrollView.hasVerticalScroller = true
            let editor = MarkdownTextView(usingTextLayoutManager: true)
            editor.frame = frame
            editor.isVerticallyResizable = true
            editor.isHorizontallyResizable = false
            editor.maxSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
            editor.textContainer?.widthTracksTextView = true
            scrollView.documentView = editor
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = scrollView
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            editor.document = MarkdownDocument(markdown: (0 ..< 300).map { "- [ ] Task \($0)" }.joined(separator: "\n"))
            window.makeFirstResponder(editor)
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            editor.selectedRange = NSRange(location: 2, length: 0)
            editor.insertText("new text ", replacementRange: editor.selectedRange)
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(editor.document.markdown.contains("Tanew text sk 0"))

            func assertVisibleCheckboxes(file: StaticString = #filePath, line: UInt = #line) throws -> [CGFloat] {
                let manager = try XCTUnwrap(editor.textLayoutManager, file: file, line: line)
                let contentManager = try XCTUnwrap(manager.textContentManager, file: file, line: line)
                let viewport = try XCTUnwrap(manager.textViewportLayoutController.viewportRange, file: file, line: line)
                let range = ProjectionUTF16Range(
                    location: contentManager.offset(from: contentManager.documentRange.location, to: viewport.location),
                    length: contentManager.offset(from: viewport.location, to: viewport.endLocation)
                )
                let offsets = editor.editingSession.projection.index.unitStartOffsets(in: range)
                let layers = (editor.layer?.sublayers ?? []).compactMap { $0 as? MarkdownTaskCheckboxLayer }
                XCTAssertGreaterThan(layers.count, 0, file: file, line: line)
                XCTAssertLessThan(layers.count, 30, file: file, line: line)
                XCTAssertEqual(layers.count, offsets.count, file: file, line: line)
                for (layer, offset) in zip(layers, offsets) {
                    var actualRange = NSRange()
                    let screenRect = editor.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: &actualRange)
                    let textRect = editor.convert(window.convertFromScreen(screenRect), from: nil)
                    XCTAssertEqual(layer.frame.midY, textRect.midY, accuracy: 0.5, file: file, line: line)
                }
                return layers.map(\.frame.midY)
            }

            let initialPositions = try assertVisibleCheckboxes()
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 1600))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            let scrolledPositions = try assertVisibleCheckboxes()
            XCTAssertNotEqual(initialPositions, scrolledPositions)
            XCTAssertGreaterThan(scrolledPositions.first ?? 0, 1000)

            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(try assertVisibleCheckboxes(), initialPositions)
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

        func testMarkedTextCompositionKeepsSurroundingText() {
            enum Commit {
                case unmark
                case insert(String)
            }
            let cases: [(name: String, steps: [String], commit: Commit, expected: String)] = [
                ("grows", ["n", "ni", "nih"], .unmark, "abnihc\n\ndef\n"),
                ("shrinks", ["n", "ni", "nih", "niha", "nihao"], .insert("你好"), "ab你好c\n\ndef\n"),
                ("is replaced", ["に", "にほ", "にほん"], .insert("日本"), "ab日本c\n\ndef\n"),
                ("is cancelled", ["n", "ni", ""], .unmark, "abc\n\ndef\n")
            ]
            for testCase in cases {
                let textView = MarkdownTextView(usingTextLayoutManager: true)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                window.contentView = textView
                window.makeFirstResponder(textView)
                textView.document = MarkdownDocument(markdown: "abc\n\ndef")
                textView.selectedRange = NSRange(location: 2, length: 0)
                let notFound = NSRange(location: NSNotFound, length: 0)

                for step in testCase.steps {
                    textView.setMarkedText(
                        step,
                        selectedRange: NSRange(location: step.utf16.count, length: 0),
                        replacementRange: notFound
                    )
                }
                switch testCase.commit {
                    case .unmark:
                        textView.unmarkText()
                    case let .insert(text):
                        textView.insertText(text, replacementRange: notFound)
                }

                XCTAssertFalse(textView.hasMarkedText(), testCase.name)
                XCTAssertEqual(textView.document.markdown, testCase.expected, testCase.name)
                assertMatchesFreshProjection(textView, testCase.name)
            }
        }

        func testTabIndentsAndShiftTabOutdentsListItemsUntilTheyBecomeParagraphs() throws {
            let (textView, window) = makeFocusedTextView("- A\n- B")
            defer { window.contentView = nil }
            textView.selectedRange = NSRange(location: 3, length: 0)

            textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
            XCTAssertEqual(textView.document, MarkdownDocument(markdown: "- A\n  - B"))

            textView.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
            XCTAssertEqual(textView.document, MarkdownDocument(markdown: "- A\n- B"))

            textView.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
            XCTAssertEqual(textView.document, MarkdownDocument(markdown: "- A\n\nB"))
            XCTAssertEqual(textView.selectedRange, NSRange(location: 3, length: 0))

            try XCTUnwrap(textView.undoManager).undo()
            XCTAssertEqual(textView.document, MarkdownDocument(markdown: "- A\n- B"))
        }

        func testTabOutsideListKeepsInsertingATab() {
            let (textView, window) = makeFocusedTextView("text")
            defer { window.contentView = nil }
            textView.selectedRange = NSRange(location: 4, length: 0)

            textView.doCommand(by: #selector(NSResponder.insertTab(_:)))

            XCTAssertEqual(textView.document.blocks, [.paragraph([.text("text\t")])])
        }

        func testShiftReturnInsertsHardLineBreakSavedAsTrailingBackslash() throws {
            let (textView, window) = makeFocusedTextView("abcd")
            defer { window.contentView = nil }
            textView.selectedRange = NSRange(location: 2, length: 0)

            textView.keyDown(with: try keyEvent("\r", modifiers: .shift, in: window))

            XCTAssertEqual(textView.document.markdown, "ab\\\ncd\n")
            XCTAssertEqual(MarkdownDocument(markdown: textView.document.markdown), textView.document)
            XCTAssertEqual(textView.string, "ab\ncd\n")
            XCTAssertEqual(textView.selectedRange, NSRange(location: 3, length: 0))
        }

        func testShiftCommandXTogglesStrikethroughOnlyWhileTheEditorHasFocus() throws {
            let (textView, window) = makeFocusedTextView("text")
            defer { window.contentView = nil }
            textView.selectedRange = NSRange(location: 0, length: 4)
            let event = try keyEvent("X", ignoringModifiers: "X", modifiers: [.command, .shift], in: window)

            XCTAssertTrue(textView.performKeyEquivalent(with: event))
            XCTAssertEqual(textView.document.markdown, "~~text~~\n")
            try XCTUnwrap(textView.undoManager).undo()
            XCTAssertEqual(textView.document.markdown, "text\n")

            let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            window.contentView?.addSubview(other)
            window.makeFirstResponder(other)
            XCTAssertFalse(textView.performKeyEquivalent(with: event))
            XCTAssertEqual(textView.document.markdown, "text\n")
        }

        func testShortcutsDoNotEditANonEditableEditor() throws {
            let (textView, window) = makeFocusedTextView("- A\n- B")
            defer { window.contentView = nil }
            textView.isEditable = false
            textView.selectedRange = NSRange(location: 2, length: 3)

            textView.insertTab(nil)
            XCTAssertFalse(textView.performKeyEquivalent(with: try keyEvent("X", ignoringModifiers: "X", modifiers: [.command, .shift], in: window)))

            XCTAssertEqual(textView.document, MarkdownDocument(markdown: "- A\n- B"))
        }

        func testCommandKPresentsLinkEditorOnlyWhenTheSwiftUIEditorInstallsIt() throws {
            let (textView, window) = makeFocusedTextView("text")
            defer { window.contentView = nil }
            textView.selectedRange = NSRange(location: 0, length: 4)
            let event = try keyEvent("k", modifiers: .command, in: window)
            XCTAssertFalse(textView.performKeyEquivalent(with: event))

            var presentations = 0
            textView.presentLinkEditor = { presentations += 1 }
            XCTAssertTrue(textView.performKeyEquivalent(with: event))
            XCTAssertEqual(presentations, 1)
            XCTAssertEqual(textView.document.markdown, "text\n")
        }

        func testContextMenuShowsStrikethroughAndLinkShortcuts() throws {
            let (textView, window) = makeFocusedTextView("text")
            defer { window.contentView = nil }
            textView.selectedRange = NSRange(location: 0, length: 4)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            XCTAssertNil(textView.menu(for: event)?.item(withTitle: "Add or Edit Link…"))

            textView.presentLinkEditor = {}
            let menu = try XCTUnwrap(textView.menu(for: event))
            let strikethrough = try XCTUnwrap(menu.item(withTitle: "Style")?.submenu?.item(withTitle: "Strikethrough"))
            XCTAssertEqual(strikethrough.keyEquivalent, "x")
            XCTAssertEqual(strikethrough.keyEquivalentModifierMask, [.command, .shift])
            let link = try XCTUnwrap(menu.item(withTitle: "Add or Edit Link…"))
            XCTAssertEqual(link.keyEquivalent, "k")
            XCTAssertEqual(link.keyEquivalentModifierMask, .command)
        }

        func testTypedMarkdownShortcutConvertsOnlyWhenTurnedOnAndUndoKeepsTheText() throws {
            let (textView, window) = makeFocusedTextView("")
            defer { window.contentView = nil }
            XCTAssertFalse(textView.convertsMarkdownShortcuts)
            textView.document = MarkdownDocument(blocks: [.paragraph([.text(">")])])
            textView.selectedRange = NSRange(location: 1, length: 0)
            textView.insertText(" ", replacementRange: textView.selectedRange)
            XCTAssertEqual(textView.document.blocks, [.paragraph([.text("> ")])])
            // Tests run in one event, so keep the literal insertion out of the undo group below.
            try XCTUnwrap(textView.undoManager).removeAllActions()

            textView.convertsMarkdownShortcuts = true
            textView.document = MarkdownDocument(blocks: [.paragraph([.text(">")])])
            textView.selectedRange = NSRange(location: 1, length: 0)
            textView.insertText(" ", replacementRange: textView.selectedRange)
            XCTAssertEqual(textView.document.blocks, [.blockquote([.paragraph([])])])
            XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0))

            try XCTUnwrap(textView.undoManager).undo()
            XCTAssertEqual(textView.document.blocks, [.paragraph([.text("> ")])])
            XCTAssertEqual(textView.string, "> \n")
            XCTAssertEqual(textView.selectedRange, NSRange(location: 2, length: 0))

            textView.convertsMarkdownShortcuts = false
            textView.document = MarkdownDocument(blocks: [.paragraph([.text("```swift")])])
            textView.selectedRange = NSRange(location: 8, length: 0)
            textView.insertNewline(nil)
            XCTAssertEqual(textView.document.blocks, [.paragraph([.text("```swift")]), .paragraph([])])
        }

        private func makeFocusedTextView(_ markdown: String) -> (MarkdownTextView, NSWindow) {
            let textView = MarkdownTextView(usingTextLayoutManager: true)
            textView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
            let window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = textView
            textView.document = MarkdownDocument(markdown: markdown)
            window.makeFirstResponder(textView)
            return (textView, window)
        }

        private func keyEvent(
            _ characters: String,
            ignoringModifiers: String? = nil,
            modifiers: NSEvent.ModifierFlags,
            in window: NSWindow
        ) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: ignoringModifiers ?? characters, isARepeat: false, keyCode: 0
            ))
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

        private func assertMatchesFreshProjection(
            _ textView: MarkdownTextView,
            _ message: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let session = textView.editingSession
            let expected = MarkdownProjectionBuilder().build(document: session.document, theme: session.theme)
            XCTAssertEqual(textView.string, expected.string, message, file: file, line: line)
            XCTAssertEqual(session.projection.string, textView.string, message, file: file, line: line)
            // Native typing defers source mappings, so only projection ranges are compared.
            XCTAssertEqual(
                session.projection.index.units.map { "\($0.path) \($0.projectionRange)" },
                expected.index.units.map { "\($0.path) \($0.projectionRange)" },
                message,
                file: file,
                line: line
            )
        }
    }

    @MainActor private final class Delegate: MarkdownTextViewDelegate {
        private(set) var documents: [MarkdownDocument] = []

        func markdownTextView(_ textView: MarkdownTextView, didChange document: MarkdownDocument) {
            documents.append(document)
        }
    }
#endif
