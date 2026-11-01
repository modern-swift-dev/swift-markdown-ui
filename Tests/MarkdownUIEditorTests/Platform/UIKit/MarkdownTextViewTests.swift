#if os(iOS) || targetEnvironment(macCatalyst)
    @testable import MarkdownUIEditor
    import UIKit
    import XCTest

    @MainActor final class MarkdownTextViewTests: XCTestCase {
        func testEditorIgnoresUnrelatedUndoNotifications() {
            let editor = MarkdownTextView(usingTextLayoutManager: true)
            editor.document = MarkdownDocument(markdown: "text")
            var updates = 0
            editor.editingSession.onCommandStateChange = { updates += 1 }

            NotificationCenter.default.post(name: .NSUndoManagerDidUndoChange, object: UndoManager())
            NotificationCenter.default.post(name: .NSUndoManagerDidRedoChange, object: UndoManager())

            XCTAssertEqual(updates, 0)
        }

        func testUndoNotificationsFollowAttachedEditorManager() throws {
            let editor = makeTextView()
            editor.document = MarkdownDocument(markdown: "text")
            editor.becomeFirstResponder()
            let manager = try XCTUnwrap(editor.undoManager)
            var updates = 0
            editor.editingSession.onCommandStateChange = { updates += 1 }

            NotificationCenter.default.post(name: .NSUndoManagerDidUndoChange, object: UndoManager())
            XCTAssertEqual(updates, 0)
            NotificationCenter.default.post(name: .NSUndoManagerDidUndoChange, object: manager)
            XCTAssertGreaterThan(updates, 0)
            updates = 0
            NotificationCenter.default.post(name: .NSUndoManagerDidRedoChange, object: manager)
            XCTAssertGreaterThan(updates, 0)
        }

        func testEditMenuFormatsItsSelectionWithoutTableActions() throws {
            for (title, expected) in [("Bold", "**hello** world\n"), ("Italic", "*hello* world\n"), ("Strikethrough", "~~hello~~ world\n")] {
                let editor = makeTextView()
                editor.document = MarkdownDocument(markdown: "hello world")
                editor.becomeFirstResponder()
                editor.selectedRange = NSRange(location: 0, length: 5)
                let suggested = UIAction(title: "Copy") { _ in }
                let menu = try XCTUnwrap(editor.delegate?.textView?(editor, editMenuForTextIn: editor.selectedRange, suggestedActions: [suggested]))
                XCTAssertTrue(menu.children.contains { $0 === suggested })
                let submenus = menu.children.compactMap { $0 as? UIMenu }
                XCTAssertFalse(submenus.contains { $0.title == "Table" })
                let style = try XCTUnwrap(submenus.first { $0.title == "Style" })
                let action = try XCTUnwrap(style.children.compactMap { $0 as? UIAction }.first { $0.title == title })
                XCTAssertFalse(action.attributes.contains(.disabled))
                editor.selectedRange = NSRange(location: 6, length: 5)
                let button = UIButton(type: .system)
                button.addAction(action, for: .touchUpInside)
                button.sendActions(for: .touchUpInside)
                XCTAssertEqual(editor.document.markdown, expected)
                editor.undoManager?.undo()
                XCTAssertEqual(editor.document.markdown, "hello world\n")
            }
        }

        func testDocumentCanBeSetBeforeMovingToWindow() {
            let textView = MarkdownTextView(usingTextLayoutManager: true)

            textView.document = MarkdownDocument(markdown: "hello")

            XCTAssertEqual(textView.document.markdown, "hello\n")
        }

        func testTextKit2RemainsActiveAfterDocumentUpdatesCommandsAndUndo() {
            let textView = makeTextView()
            textView.document = MarkdownDocument(markdown: "hello")
            assertTextKit2IsActive(in: textView)

            textView.selectedRange = NSRange(location: 0, length: 5)
            textView.perform(.toggleInline(.strong))
            assertTextKit2IsActive(in: textView)

            textView.undoManager?.undo()
            assertTextKit2IsActive(in: textView)
        }

        func testDelegateReceivesDocumentChanges() {
            let textView = makeTextView()
            let delegate = Delegate()
            textView.markdownDelegate = delegate
            textView.document = MarkdownDocument(markdown: "hello")
            textView.selectedRange = NSRange(location: 0, length: 5)

            textView.perform(.toggleInline(.strong))

            XCTAssertEqual(delegate.documents.last?.markdown, "**hello**\n")
        }

        func testStrikethroughActionChangesTheDocument() {
            let textView = makeTextView()
            textView.document = MarkdownDocument(markdown: "hello")
            textView.selectedRange = NSRange(location: 0, length: 5)

            textView.perform(.toggleInline(.strikethrough))

            XCTAssertEqual(textView.document.markdown, "~~hello~~\n")
        }

        func testStyleSelectorsParticipateInNativeActionValidation() {
            let textView = makeTextView()
            textView.document = MarkdownDocument(markdown: "hello")
            textView.selectedRange = NSRange(location: 0, length: 5)

            XCTAssertTrue(textView.canPerformAction(NSSelectorFromString("toggleStrong"), withSender: nil))
            XCTAssertTrue(textView.canPerformAction(NSSelectorFromString("toggleEmphasis"), withSender: nil))
            XCTAssertTrue(textView.canPerformAction(NSSelectorFromString("toggleStrikethrough"), withSender: nil))
            XCTAssertTrue(textView.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        }

        func testTaskToggleAtProjectionPositionPublishesAndPreservesSelection() {
            let textView = makeTextView()
            let delegate = Delegate()
            textView.markdownDelegate = delegate
            textView.document = MarkdownDocument(markdown: "- [ ] task")
            textView.selectedRange = NSRange(location: 2, length: 0)

            XCTAssertTrue(textView.editingSession.toggleTask(atProjectionUTF16Offset: 0))

            XCTAssertEqual(textView.document.markdown, "  - [x] task\n")
            XCTAssertEqual(textView.selectedRange, NSRange(location: 2, length: 0))
            XCTAssertEqual(delegate.documents.last?.markdown, "  - [x] task\n")
        }

        func testTaskToggleAtProjectionPositionRejectsOrdinaryListItems() {
            let textView = makeTextView()
            textView.document = MarkdownDocument(markdown: "- item")

            XCTAssertFalse(textView.editingSession.toggleTask(atProjectionUTF16Offset: 0))
            XCTAssertEqual(textView.document.markdown, "  - item\n")
        }

        func testLargerCheckboxTargetsAndCompletedTextEditing() throws {
            let textView = makeTextView()
            textView.document = MarkdownDocument(markdown: "- [ ] task\n- [x] done")
            textView.layoutIfNeeded()
            let boxes = textView.layer.sublayers?.compactMap { $0 as? MarkdownTaskCheckboxLayer } ?? []
            XCTAssertEqual(boxes.count, 2)
            let firstBox = try XCTUnwrap(boxes.first)
            let bodyFont = try XCTUnwrap(textView.editorTheme.bodyAttributes[.font] as? UIFont)
            XCTAssertEqual(firstBox.frame.width, bodyFont.pointSize * 1.2, accuracy: 0.01)
            let point = CGPoint(x: firstBox.frame.minX - 8, y: firstBox.frame.midY)
            let offset = try XCTUnwrap(textView.taskMarkerOffset(at: point))
            XCTAssertEqual(offset, 0)
            let secondBox = try XCTUnwrap(boxes.last)
            XCTAssertEqual(textView.taskMarkerOffset(at: CGPoint(x: secondBox.frame.midX, y: secondBox.frame.midY)), 5)
            XCTAssertNil(textView.taskMarkerOffset(at: CGPoint(x: firstBox.frame.maxX + 20, y: firstBox.frame.midY)))

            _ = textView.becomeFirstResponder()
            textView.selectedRange = NSRange(location: 4, length: 0)
            XCTAssertTrue(textView.editingSession.toggleTask(atProjectionUTF16Offset: offset))
            textView.insertText("!")
            XCTAssertEqual(textView.textStorage.attribute(.strikethroughStyle, at: 4, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
            XCTAssertTrue(textView.editingSession.toggleTask(atProjectionUTF16Offset: offset))
            XCTAssertNil(textView.textStorage.attribute(.strikethroughStyle, at: 4, effectiveRange: nil))
            XCTAssertEqual(textView.document, MarkdownDocument(markdown: "- [ ] task!\n- [x] done"))

            for fontSize: CGFloat in [12, 36] {
                let base = textView.editorTheme
                var body = base.bodyAttributes
                body[.font] = UIFont.systemFont(ofSize: fontSize)
                textView.editorTheme = MarkdownEditorTheme(
                    bodyAttributes: body,
                    headingAttributes: base.headingAttributes,
                    codeAttributes: base.codeAttributes,
                    sourceAttributes: base.sourceAttributes,
                    linkAttributes: base.linkAttributes,
                    objectPlaceholderAttributes: base.objectPlaceholderAttributes
                )
                textView.layoutIfNeeded()
                XCTAssertEqual(firstBox.frame.width, fontSize * 1.2, accuracy: 0.01)
                let position = try XCTUnwrap(textView.position(from: textView.beginningOfDocument, offset: 0))
                let target = MarkdownTaskCheckboxLayer.hitBounds(textRect: textView.caretRect(for: position), theme: textView.editorTheme)
                XCTAssertGreaterThanOrEqual(target.width, 44)
                XCTAssertTrue(target.contains(firstBox.frame))
                XCTAssertEqual(textView.taskMarkerOffset(at: CGPoint(x: target.minX + 1, y: target.midY)), 0)
            }
        }

        func testCheckboxPlacementIsReusedOnlyWhileItsInputsAreUnchanged() throws {
            let markdown = (0 ..< 120).map { "- [ ] task \($0)" }.joined(separator: "\n")
            let textView = makeTextView()
            // Recomputes on every pass, as before placements were reused.
            let reference = makeTextView()
            for view in [textView, reference] {
                view.document = MarkdownDocument(markdown: markdown)
                view.layoutIfNeeded()
            }
            // The viewport settles one pass after the first layout.
            textView.layoutSubviews()
            let placements = textView.taskCheckboxPlacementCount
            textView.layoutSubviews()
            textView.layoutSubviews()
            XCTAssertEqual(textView.taskCheckboxPlacementCount, placements, "An unchanged layout pass must reuse the placement")

            var skipped = 0
            for step in 1 ... 40 {
                let before = textView.taskCheckboxPlacementCount
                for view in [textView, reference] {
                    view.contentOffset.y = CGFloat(step * 9)
                }
                textView.layoutIfNeeded()
                reference.setNeedsLayout()
                reference.layoutIfNeeded()
                if textView.taskCheckboxPlacementCount == before {
                    skipped += 1
                }
                XCTAssertEqual(checkboxFrames(in: textView), checkboxFrames(in: reference), "Reused placement differs at step \(step)")
            }
            XCTAssertGreaterThan(skipped, 0)

            let firstBox = try XCTUnwrap(textView.layer.sublayers?.compactMap { $0 as? MarkdownTaskCheckboxLayer }.first)
            let uncheckedPath = firstBox.path
            textView.contentOffset = .zero
            textView.layoutIfNeeded()
            XCTAssertTrue(textView.editingSession.toggleTask(atProjectionUTF16Offset: 0))
            textView.layoutIfNeeded()
            XCTAssertNotEqual(firstBox.path, uncheckedPath, "A task toggle must redraw its checkbox")

            let before = textView.taskCheckboxPlacementCount
            textView.frame.size.width -= 40
            textView.layoutIfNeeded()
            XCTAssertGreaterThan(textView.taskCheckboxPlacementCount, before, "A width change must place checkboxes again")
        }

        private func checkboxFrames(in textView: MarkdownTextView) -> [CGRect] {
            textView.layer.sublayers?.compactMap { ($0 as? MarkdownTaskCheckboxLayer)?.frame } ?? []
        }

        func testSelectionForwardsThroughTheTextViewBridge() {
            let textView = makeTextView()
            textView.document = MarkdownDocument(markdown: "hello")

            textView.selectedRange = NSRange(location: 2, length: 0)

            XCTAssertEqual(textView.markdownSelectedRanges, [NSRange(location: 2, length: 0)])
        }

        func testTypingAttributesForwardThroughTheTextViewBridge() {
            let textView = makeTextView()
            let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.systemRed]

            textView.markdownTypingAttributes = attributes

            XCTAssertEqual(textView.markdownTypingAttributes[.foregroundColor] as? UIColor, UIColor.systemRed)
        }

        func testReturnAtEndOfOrderedListBeforeUnorderedListCreatesOrderedItem() {
            let textView = makeTextView()
            textView.document = MarkdownDocument(markdown: """
            1. Draft the release notes
            2. Review the changes

            - Build the example apps
            - Run the snapshot tests
            """)
            let reviewRange = (textView.text as NSString).range(of: "Review the changes")
            textView.selectedRange = NSRange(location: NSMaxRange(reviewRange), length: 0)

            let shouldInsert = textView.delegate?.textView?(
                textView,
                shouldChangeTextIn: textView.selectedRange,
                replacementText: "\n"
            )

            XCTAssertEqual(shouldInsert, false)
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
                textView.text,
                "Draft the release notes\nReview the changes\n\nBuild the example apps\nRun the snapshot tests\n"
            )
        }

        func testNativeTypingIntoEmptyDocumentPersistsAndMovesCaret() {
            let textView = makeTextView()
            textView.document = MarkdownDocument(markdown: "")
            XCTAssertTrue(textView.becomeFirstResponder())
            textView.selectedRange = NSRange(location: 0, length: 0)

            textView.insertText("hello")

            XCTAssertEqual(textView.document.markdown, "hello\n")
            XCTAssertEqual(textView.text, "hello\n")
            XCTAssertEqual(textView.selectedRange, NSRange(location: 5, length: 0))
        }

        func testNativeTypingAfterFinalProjectionNewlinePersists() {
            let textView = makeTextView()
            textView.document = MarkdownDocument(markdown: "abc")
            XCTAssertTrue(textView.becomeFirstResponder())
            textView.selectedRange = NSRange(location: textView.text.utf16.count, length: 0)

            textView.insertText("X")

            XCTAssertEqual(textView.document.markdown, "abcX\n")
            XCTAssertEqual(textView.text, "abcX\n")
            XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 0))
        }

        func testNativeCrossParagraphReplacementPreservesBoundaryText() {
            let textView = makeTextView()
            textView.document = MarkdownDocument(markdown: "abc\n\ndef")
            XCTAssertTrue(textView.becomeFirstResponder())
            textView.selectedRange = NSRange(location: 1, length: 4)

            textView.insertText("X")

            XCTAssertEqual(textView.document.markdown, "aXef\n")
            XCTAssertEqual(textView.text, "aXef\n")
            XCTAssertEqual(textView.selectedRange, NSRange(location: 2, length: 0))
        }

        func testNativeSelectAllDeleteAllowsTypingAgain() {
            let textView = makeTextView()
            textView.document = MarkdownDocument(markdown: "abc\n\ndef")
            XCTAssertTrue(textView.becomeFirstResponder())
            textView.selectedRange = NSRange(location: 0, length: textView.text.utf16.count)

            textView.deleteBackward()

            XCTAssertTrue(textView.document.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0))
            textView.insertText("new")
            XCTAssertEqual(textView.document.markdown, "new\n")
            XCTAssertEqual(textView.text, "new\n")
        }

        func testNativeSelectionFormatsAcrossParagraphsAndUndoRestoresDocument() throws {
            let textView = makeTextView()
            textView.document = MarkdownDocument(markdown: "abc\n\ndef")
            XCTAssertTrue(textView.becomeFirstResponder())
            textView.selectedRange = NSRange(location: 0, length: 7)

            textView.perform(.toggleInline(.strong))

            XCTAssertEqual(textView.document.markdown, "**abc**\n\n**def**\n")
            XCTAssertEqual(textView.text, "abc\ndef\n")
            XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 7))
            let undoManager = try XCTUnwrap(textView.undoManager)
            undoManager.undo()
            XCTAssertEqual(textView.document.markdown, "abc\n\ndef\n")
            XCTAssertEqual(textView.text, "abc\ndef\n")
            undoManager.redo()
            XCTAssertEqual(textView.document.markdown, "**abc**\n\n**def**\n")
        }

        func testCommandRestoresFocusAndNativeTypingKeepsCaretStyle() throws {
            let textView = makeTextView()
            textView.document = MarkdownDocument(markdown: "hello")
            XCTAssertTrue(textView.becomeFirstResponder())
            textView.selectedRange = NSRange(location: 5, length: 0)
            textView.resignFirstResponder()

            textView.perform(.toggleInline(.strong))

            XCTAssertTrue(textView.isFirstResponder)
            XCTAssertEqual(textView.selectedRange, NSRange(location: 5, length: 0))
            textView.insertText("X")
            XCTAssertEqual(textView.document.markdown, "hello**X**\n")
            XCTAssertEqual(textView.text, "helloX\n")
            XCTAssertEqual(textView.selectedRange, NSRange(location: 6, length: 0))
            let undoManager = try XCTUnwrap(textView.undoManager)
            undoManager.undo()
            XCTAssertEqual(textView.document.markdown, "hello\n")
            XCTAssertEqual(textView.text, "hello\n")
            undoManager.redo()
            XCTAssertEqual(textView.document.markdown, "hello**X**\n")
            XCTAssertEqual(textView.text, "helloX\n")
        }

        func testNativeDeleteBackwardRemovesAnEntireEmoji() {
            let textView = makeTextView()
            textView.document = MarkdownDocument(markdown: "a👩🏽‍💻b")
            XCTAssertTrue(textView.becomeFirstResponder())
            textView.selectedRange = NSRange(location: "a👩🏽‍💻".utf16.count, length: 0)

            textView.deleteBackward()

            XCTAssertEqual(textView.document.markdown, "ab\n")
            XCTAssertEqual(textView.text, "ab\n")
            XCTAssertEqual(textView.selectedRange, NSRange(location: 1, length: 0))
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
                let textView = makeTextView()
                textView.document = MarkdownDocument(markdown: "abc\n\ndef")
                XCTAssertTrue(textView.becomeFirstResponder())
                textView.selectedRange = NSRange(location: 2, length: 0)

                for step in testCase.steps {
                    textView.setMarkedText(step, selectedRange: NSRange(location: step.utf16.count, length: 0))
                }
                switch testCase.commit {
                    case .unmark:
                        textView.unmarkText()
                    case let .insert(text):
                        textView.insertText(text)
                }

                XCTAssertNil(textView.markedTextRange, testCase.name)
                XCTAssertEqual(textView.document.markdown, testCase.expected, testCase.name)
                let session = textView.editingSession
                let expected = MarkdownProjectionBuilder().build(document: session.document, theme: session.theme)
                XCTAssertEqual(textView.text, expected.string, testCase.name)
                XCTAssertEqual(session.projection.string, textView.text, testCase.name)
                // Native typing defers source mappings, so only projection ranges are compared.
                XCTAssertEqual(
                    session.projection.index.units.map { "\($0.path) \($0.projectionRange)" },
                    expected.index.units.map { "\($0.path) \($0.projectionRange)" },
                    testCase.name
                )
            }
        }

        func testUIKitImplementationDoesNotReferenceTheForbiddenTextKit1Symbol() throws {
            let testFileURL = URL(fileURLWithPath: #filePath)
            let sourceURL = testFileURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/MarkdownUIEditor/Platform/UIKit/UIKitMarkdownTextView.swift")
            let source = try String(contentsOf: sourceURL)

            XCTAssertFalse(source.contains(".layout" + "Manager"))
        }

        func testHardwareKeyboardShortcutsAreDiscoverable() throws {
            let textView = makeTextView()
            textView.document = MarkdownDocument(markdown: "text")
            let expected: [(String, String, UIKeyModifierFlags)] = [
                ("Strikethrough", "x", [.command, .shift]),
                ("Indent", "\t", []),
                ("Outdent", "\t", .shift),
                ("Line Break", "\r", .shift)
            ]
            for (title, input, modifiers) in expected {
                let command = try XCTUnwrap(keyCommand(input, modifiers, in: textView), title)
                XCTAssertEqual(command.discoverabilityTitle, title)
            }
            XCTAssertNil(keyCommand("k", .command, in: textView), "Only the SwiftUI editor offers ⌘K")

            var presentations = 0
            textView.presentLinkEditor = { presentations += 1 }
            XCTAssertTrue(textView.becomeFirstResponder())
            textView.selectedRange = NSRange(location: 0, length: 4)
            let link = try XCTUnwrap(keyCommand("k", .command, in: textView))
            XCTAssertEqual(link.discoverabilityTitle, "Add or Edit Link")
            XCTAssertTrue(send(link, to: textView))
            XCTAssertEqual(presentations, 1)
            XCTAssertEqual(textView.document.markdown, "text\n")
        }

        func testTabAndShiftTabIndentAndOutdentListItemsOnly() throws {
            let textView = makeTextView()
            textView.document = MarkdownDocument(markdown: "- A\n- B\n\ntext")
            XCTAssertTrue(textView.becomeFirstResponder())
            let tab = try XCTUnwrap(keyCommand("\t", [], in: textView))
            let shiftTab = try XCTUnwrap(keyCommand("\t", .shift, in: textView))

            textView.selectedRange = NSRange(location: 6, length: 0)
            XCTAssertFalse(textView.canPerformAction(try XCTUnwrap(tab.action), withSender: tab), "Tab outside a list keeps its behavior")
            XCTAssertFalse(textView.canPerformAction(try XCTUnwrap(shiftTab.action), withSender: shiftTab))

            textView.selectedRange = NSRange(location: 3, length: 0)
            XCTAssertTrue(send(tab, to: textView))
            XCTAssertEqual(textView.document, MarkdownDocument(markdown: "- A\n  - B\n\ntext"))
            XCTAssertTrue(send(shiftTab, to: textView))
            XCTAssertTrue(send(shiftTab, to: textView))
            XCTAssertEqual(textView.document, MarkdownDocument(markdown: "- A\n\nB\n\ntext"))
            textView.undoManager?.undo()
            XCTAssertEqual(textView.document, MarkdownDocument(markdown: "- A\n- B\n\ntext"))
        }

        func testShiftReturnAndShiftCommandXEditTheFocusedEditor() throws {
            let textView = makeTextView()
            textView.document = MarkdownDocument(markdown: "abcd")
            XCTAssertTrue(textView.becomeFirstResponder())

            textView.selectedRange = NSRange(location: 2, length: 0)
            XCTAssertTrue(send(try XCTUnwrap(keyCommand("\r", .shift, in: textView)), to: textView))
            XCTAssertEqual(textView.document.markdown, "ab\\\ncd\n")
            XCTAssertEqual(MarkdownDocument(markdown: textView.document.markdown), textView.document)
            XCTAssertEqual(textView.selectedRange, NSRange(location: 3, length: 0))

            textView.selectedRange = NSRange(location: 0, length: 5)
            XCTAssertTrue(send(try XCTUnwrap(keyCommand("x", [.command, .shift], in: textView)), to: textView))
            XCTAssertEqual(textView.document.markdown, "~~ab\\\ncd~~\n")
        }

        func testShortcutsDoNotFireWithoutFocusOrWhenNotEditable() {
            let textView = makeTextView()
            textView.document = MarkdownDocument(markdown: "- A\n- B")
            textView.presentLinkEditor = {}
            textView.selectedRange = NSRange(location: 3, length: 0)
            let actions = [("\t", UIKeyModifierFlags()), ("\t", .shift), ("\r", .shift), ("k", .command)]
                .compactMap { keyCommand($0.0, $0.1, in: textView)?.action }
            XCTAssertEqual(actions.count, 4)

            for action in actions {
                XCTAssertFalse(textView.canPerformAction(action, withSender: nil), "\(action) without focus")
            }
            XCTAssertTrue(textView.becomeFirstResponder())
            textView.selectedRange = NSRange(location: 3, length: 0)
            textView.isEditable = false
            for action in actions {
                XCTAssertFalse(textView.canPerformAction(action, withSender: nil), "\(action) when not editable")
            }
        }

        func testTypedMarkdownShortcutConvertsOnlyWhenTurnedOnAndUndoKeepsTheText() throws {
            let textView = makeTextView()
            XCTAssertTrue(textView.becomeFirstResponder())
            XCTAssertFalse(textView.convertsMarkdownShortcuts)
            textView.document = MarkdownDocument(blocks: [.paragraph([.text("##")])])
            textView.selectedRange = NSRange(location: 2, length: 0)
            textView.insertText(" ")
            XCTAssertEqual(textView.document.blocks, [.paragraph([.text("## ")])])
            // Tests run in one event, so keep the literal insertion out of the undo group below.
            try XCTUnwrap(textView.undoManager).removeAllActions()

            textView.convertsMarkdownShortcuts = true
            textView.document = MarkdownDocument(blocks: [.paragraph([.text("##")])])
            textView.selectedRange = NSRange(location: 2, length: 0)
            textView.insertText(" ")
            XCTAssertEqual(textView.document.blocks, [.heading(level: .two, content: [])])
            XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0))

            try XCTUnwrap(textView.undoManager).undo()
            XCTAssertEqual(textView.document.blocks, [.paragraph([.text("## ")])])
            XCTAssertEqual(textView.text, "## \n")
            XCTAssertEqual(textView.selectedRange, NSRange(location: 3, length: 0))

            textView.document = MarkdownDocument(blocks: [.paragraph([.text("```swift")])])
            textView.selectedRange = NSRange(location: 8, length: 0)
            textView.insertText("\n")
            XCTAssertEqual(textView.document.blocks, [.codeBlock(info: "swift", content: "")])
        }

        private func keyCommand(_ input: String, _ modifiers: UIKeyModifierFlags, in textView: MarkdownTextView) -> UIKeyCommand? {
            textView.keyCommands?.first { $0.input == input && $0.modifierFlags == modifiers }
        }

        private func send(_ command: UIKeyCommand, to textView: MarkdownTextView) -> Bool {
            guard let action = command.action, textView.canPerformAction(action, withSender: command) else {
                return false
            }
            _ = textView.perform(action, with: command)
            return true
        }

        private func makeTextView() -> MarkdownTextView {
            let textView = MarkdownTextView(usingTextLayoutManager: true)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            window.rootViewController = UIViewController()
            textView.frame = window.bounds
            window.rootViewController?.view.addSubview(textView)
            window.makeKeyAndVisible()
            addTeardownBlock { @MainActor in window.isHidden = true }
            return textView
        }

        private func assertTextKit2IsActive(in textView: MarkdownTextView, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertNotNil(textView.textLayoutManager, file: file, line: line)
            XCTAssertNotNil(textView.textContainer.textLayoutManager, file: file, line: line)
        }
    }

    @MainActor private final class Delegate: MarkdownTextViewDelegate {
        private(set) var documents: [MarkdownDocument] = []

        func markdownTextView(_ textView: MarkdownTextView, didChange document: MarkdownDocument) {
            documents.append(document)
        }
    }
#endif
