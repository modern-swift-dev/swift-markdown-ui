import Foundation
@testable import MarkdownUIEditor
import XCTest

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor final class MarkdownTableAttachmentTests: XCTestCase {
    func testCellLayoutMeasuresOnlyEditedCellWhenColumnMaximumIsUnchanged() {
        let positions = (0 ..< 100).flatMap { row in
            (0 ..< 4).map { MarkdownTableCellPosition(section: .body(row: row), column: $0) }
        }
        let edited = positions[0]
        var layout = MarkdownTableCellLayoutCache(positions: positions, columnCount: 4)
        var measured: [MarkdownTableCellPosition] = []
        XCTAssertEqual(layout.update(availableWidth: nil) { position in
            measured.append(position)
            return position == edited ? 50 : 100
        }, Set(positions))
        XCTAssertEqual(measured.count, 400)

        for width in [CGFloat(60), 70, 55] {
            measured.removeAll()
            let affected = layout.update(changedCell: edited, availableWidth: nil) { position in
                measured.append(position)
                return width
            }
            XCTAssertEqual(measured, [edited])
            XCTAssertEqual(affected, [edited], "Only the edited cell should need height measurement or intrinsic-size invalidation")
            XCTAssertEqual(layout.widths, [100, 100, 100, 100])
        }
    }

    func testCellLayoutShrinkingWidestCellReflowsOnlyItsColumn() {
        let header = MarkdownTableCellPosition(section: .header, column: 0)
        let body = MarkdownTableCellPosition(section: .body(row: 0), column: 0)
        let other = MarkdownTableCellPosition(section: .header, column: 1)
        var layout = MarkdownTableCellLayoutCache(positions: [header, body, other], columnCount: 2)
        _ = layout.update(availableWidth: nil) { position in position == header ? 200 : 100 }

        var measured: [MarkdownTableCellPosition] = []
        let affected = layout.update(changedCell: header, availableWidth: nil) { position in
            measured.append(position)
            return 50
        }
        XCTAssertEqual(measured, [header])
        XCTAssertEqual(layout.widths, [100, 100])
        XCTAssertEqual(affected, [header, body], "Cached peers must determine the new maximum and rewrap when their column shrinks")
    }

    func testCellLayoutRedistributesConstrainedWidthsAndRefreshesForConfigurationChanges() {
        let first = MarkdownTableCellPosition(section: .header, column: 0)
        let second = MarkdownTableCellPosition(section: .header, column: 1)
        var layout = MarkdownTableCellLayoutCache(positions: [first, second], columnCount: 2)
        _ = layout.update(availableWidth: 200) { _ in 150 }
        XCTAssertEqual(layout.widths, [100, 100])

        let affected = layout.update(changedCell: first, availableWidth: 200) { _ in 50 }
        XCTAssertEqual(layout.widths, [50, 150])
        XCTAssertEqual(affected, [first, second], "A change in one column can release width for other columns")

        var measured: [MarkdownTableCellPosition] = []
        let refreshed = layout.update(availableWidth: 100) { position in
            measured.append(position)
            return position == first ? 50 : 150
        }
        XCTAssertEqual(Set(measured), [first, second])
        XCTAssertEqual(refreshed, [first, second])
        XCTAssertEqual(layout.widths, [50, 50])
    }

    func testNavigationVisitsHeaderThenBody() {
        let controller = MarkdownTableController(table: makeTable())

        let headerEnd = MarkdownTableCellPosition(section: .header, column: 1)
        XCTAssertEqual(
            controller.moveForward(from: headerEnd),
            MarkdownTableCellPosition(section: .body(row: 0), column: 0)
        )
        XCTAssertEqual(
            controller.moveBackward(from: MarkdownTableCellPosition(section: .body(row: 0), column: 0)),
            headerEnd
        )
        XCTAssertEqual(
            controller.moveDown(from: MarkdownTableCellPosition(section: .header, column: 1)),
            MarkdownTableCellPosition(section: .body(row: 0), column: 1)
        )
    }

    func testMovingForwardFromFinalCellAppendsRow() {
        var changes: [MarkdownTable] = []
        let controller = MarkdownTableController(table: makeTable()) { changes.append($0) }

        let destination = controller.moveForward(
            from: MarkdownTableCellPosition(section: .body(row: 0), column: 1)
        )

        XCTAssertEqual(destination, MarkdownTableCellPosition(section: .body(row: 1), column: 0))
        XCTAssertEqual(controller.table.rows.count, 2)
        XCTAssertEqual(controller.table.rows[1].cells.count, 2)
        XCTAssertEqual(changes.last, controller.table)
    }

    func testCellAndStructuralChangesReturnTypedTable() {
        var changes: [MarkdownTable] = []
        let controller = MarkdownTableController(table: makeTable()) { changes.append($0) }
        let position = MarkdownTableCellPosition(section: .body(row: 0), column: 0)

        controller.updateCell(at: position, source: "**changed**")
        controller.insertColumn(at: 1, alignment: .center)
        controller.setAlignment(.right, forColumn: 0)

        XCTAssertEqual(controller.table.rows[0].cells[0].content, [.strong([.text("changed")])])
        XCTAssertEqual(controller.table.alignments, [.right, .center, .right])
        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(changes.last, controller.table)
    }

    func testCellNewlinesRoundTripAsCanonicalHTMLBreaks() {
        let controller = MarkdownTableController(table: makeTable())
        let position = MarkdownTableCellPosition(section: .body(row: 0), column: 0)

        controller.updateCell(at: position, source: "First\n**Second**\n")

        XCTAssertEqual(controller.table.rows[0].cells[0].content, [
            .text("First"),
            .html("<br />"),
            .strong([.text("Second")]),
            .html("<br />")
        ])
        XCTAssertEqual(controller.source(at: position), "First\n**Second**\n")
        let markdown = MarkdownDocument(blocks: [.table(controller.table)]).markdown
        XCTAssertTrue(markdown.contains("First<br />**Second**<br />"))
        XCTAssertEqual(MarkdownDocument(markdown: markdown).blocks, [.table(controller.table)])
    }

    func testColumnWidthsFollowContentUntilTheyReachAvailableWidth() {
        XCTAssertEqual(
            MarkdownTableColumnLayout.widths(preferredWidths: [60, 180], availableWidth: 300),
            [60, 180]
        )

        let compressed = MarkdownTableColumnLayout.widths(
            preferredWidths: [60, 240],
            availableWidth: 180
        )

        XCTAssertEqual(compressed.reduce(0, +), 180, accuracy: 0.001)
        XCTAssertGreaterThan(compressed[1], compressed[0])
        XCTAssertGreaterThanOrEqual(compressed[0], MarkdownTableColumnLayout.minimumColumnWidth)
    }

    func testColumnsShareVeryNarrowAvailableWidthWithoutOverflowing() {
        let widths = MarkdownTableColumnLayout.widths(
            preferredWidths: [100, 200, 300],
            availableWidth: 90
        )

        XCTAssertEqual(widths, [30, 30, 30])
        XCTAssertEqual(widths.reduce(0, +), 90, accuracy: 0.001)
    }

    #if canImport(AppKit)
    func testStableCellEditsSkipAttachmentFittingUntilRowHeightChanges() throws {
        let attachment = MarkdownTableAttachment(table: sizingTable())
        let storage = NSTextContentStorage()
        let container = NSTextContainer(size: NSSize(width: 240, height: 1000))
        let provider = try XCTUnwrap(attachment.viewProvider(for: nil, location: storage.documentRange.location, textContainer: container))
        let view = try XCTUnwrap(provider.view as? AppKitMarkdownTableGridView)
        let grid = try XCTUnwrap(firstSubview(of: NSGridView.self, in: view))
        let cell = try XCTUnwrap(grid.cell(atColumnIndex: 0, rowIndex: 1).contentView as? NSTextView)
        let initialResizeCount = view.attachmentResizeCount
        let initialHeight = view.frame.height

        for text in ["a", "ab", "abc", "a\nb"] {
            cell.string = text
            view.textDidChange(Notification(name: NSText.didChangeNotification, object: cell))
            XCTAssertEqual(view.attachmentResizeCount, initialResizeCount, "Unchanged column widths and row heights must skip full grid fitting")
        }

        cell.string = "a\nb\nc\nd\ne\nf\ng"
        view.textDidChange(Notification(name: NSText.didChangeNotification, object: cell))
        XCTAssertEqual(view.attachmentResizeCount, initialResizeCount + 1)
        XCTAssertGreaterThan(view.frame.height, initialHeight)
    }

    func testTableContextMenuTargetsClickedCellAndSupportsUndo() throws {
        let editor = MarkdownTextView(usingTextLayoutManager: true)
        editor.frame = NSRect(x: 0, y: 0, width: 620, height: 400)
        let original = MarkdownDocument(markdown: "| A | B |\n| - | - |\n| a | b |")
        editor.document = original
        let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = editor
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        func tableMenu(_ section: String = "Table", selection: NSRange = NSRange(location: 0, length: 0)) throws -> NSMenu {
            if let manager = editor.textLayoutManager {
                manager.ensureLayout(for: manager.documentRange)
            }
            editor.layoutSubtreeIfNeeded()
            let grid = try XCTUnwrap(firstSubview(of: NSGridView.self, in: editor))
            let first = try XCTUnwrap(grid.cell(atColumnIndex: 0, rowIndex: 0).contentView as? NSTextView)
            let second = try XCTUnwrap(grid.cell(atColumnIndex: 1, rowIndex: 0).contentView as? NSTextView)
            window.makeFirstResponder(first)
            if selection.length > 0 {
                window.makeFirstResponder(second)
                second.setSelectedRange(selection)
            }
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: second.convert(NSPoint(x: 5, y: 5), to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
            let menu = try XCTUnwrap(second.menu(for: event))
            XCTAssertTrue(window.firstResponder === second)
            XCTAssertEqual(menu.items.count(where: { $0.title == "Table" }), 1)
            return try XCTUnwrap(menu.items.first { $0.title == section }?.submenu)
        }
        let menu = try tableMenu()
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "Delete row")).isEnabled)
        let addColumn = try XCTUnwrap(menu.item(withTitle: "Add column"))
        XCTAssertTrue(addColumn.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(addColumn.action), to: addColumn.target, from: addColumn))
        guard case let .table(table) = editor.document.blocks[0] else {
            return XCTFail("Missing table")
        }
        XCTAssertEqual(table.header.cells.map(\.content), [[.text("A")], [.text("B")], []])
        editor.undoManager?.undo()
        XCTAssertEqual(editor.document, original)
        let rowMenu = try tableMenu()
        let addRow = try XCTUnwrap(rowMenu.item(withTitle: "Add row"))
        XCTAssertTrue(addRow.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(addRow.action), to: addRow.target, from: addRow))
        guard case let .table(expanded) = editor.document.blocks[0] else {
            return XCTFail("Missing table")
        }
        XCTAssertEqual(expanded.rows.count, 2)
        let style = try tableMenu("Style", selection: NSRange(location: 0, length: 1))
        let bold = try XCTUnwrap(style.item(withTitle: "Bold"))
        XCTAssertTrue(bold.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(bold.action), to: bold.target, from: bold))
        guard case let .table(formatted) = editor.document.blocks[0] else {
            return XCTFail("Missing table")
        }
        XCTAssertEqual(formatted.header.cells[1].content, [.strong([.text("B")])])

    }

    func testHostedTableInsertionFormattingNavigationAndUndo() throws {
        let editor = MarkdownTextView(usingTextLayoutManager: true)
        editor.frame = NSRect(x: 0, y: 0, width: 620, height: 400)
        editor.document = MarkdownDocument(markdown: "Before")
        let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = editor
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.makeFirstResponder(editor)
        editor.selectedRange = NSRange(location: 6, length: 0)
        editor.perform(.insertTable(columns: 2, bodyRows: 1))

        func layout() {
            if let manager = editor.textLayoutManager {
                manager.ensureLayout(for: manager.documentRange)
            }
            editor.layoutSubtreeIfNeeded()
        }
        func firstCell() throws -> NSTextView {
            layout()
            let grid = try XCTUnwrap(firstSubview(of: NSGridView.self, in: editor))
            return try XCTUnwrap(grid.cell(atColumnIndex: 0, rowIndex: 0).contentView as? NSTextView)
        }
        func table() throws -> MarkdownTable {
            try XCTUnwrap(editor.document.blocks.compactMap { block -> MarkdownTable? in
                if case let .table(table) = block {
                    return table
                }
                return nil
            }.first)
        }
        var cell = try firstCell()
        XCTAssertTrue(window.firstResponder === cell)
        XCTAssertEqual(cell.selectedRange(), NSRange(location: 0, length: 0))
        cell.insertText("bold tail", replacementRange: cell.selectedRange())
        cell.setSelectedRange(NSRange(location: 0, length: 4))
        let boldKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "b",
            charactersIgnoringModifiers: "b",
            isARepeat: false,
            keyCode: 11
        ))
        XCTAssertTrue(cell.performKeyEquivalent(with: boldKey))
        cell = try firstCell()
        XCTAssertTrue(window.firstResponder === cell)
        XCTAssertEqual(cell.selectedRange(), NSRange(location: 0, length: 4))
        cell.setSelectedRange(NSRange(location: 5, length: 4))
        editor.perform(.toggleInline(.emphasis))
        cell = try firstCell()
        XCTAssertEqual(cell.string, "bold tail")
        XCTAssertEqual(cell.selectedRange(), NSRange(location: 5, length: 4))
        XCTAssertEqual(try table().header.cells[0].content, [.strong([.text("bold")]), .text(" "), .emphasis([.text("tail")])])

        cell.setSelectedRange(NSRange(location: 9, length: 0))
        editor.perform(.toggleInline(.strong))
        XCTAssertTrue(window.firstResponder === cell)
        cell.insertText("!", replacementRange: cell.selectedRange())
        XCTAssertTrue(editor.document.markdown.contains("!"))
        XCTAssertEqual(cell.attributedString().attribute(.markdownEditorStrong, at: 9, effectiveRange: nil) as? NSNumber, true)
        let beforeRow = editor.document
        let undoManager = try XCTUnwrap(editor.undoManager)
        while undoManager.groupingLevel > 0 {
            undoManager.endUndoGrouping()
        }
        undoManager.removeAllActions()
        undoManager.beginUndoGrouping()
        editor.perform(.insertTableRow)
        undoManager.endUndoGrouping()
        layout()
        XCTAssertEqual(try table().rows.count, 2)
        XCTAssertTrue(window.firstResponder is NSTextView)
        XCTAssertFalse(window.firstResponder === editor)
        let afterRow = editor.document
        undoManager.undo()
        layout()
        XCTAssertEqual(editor.document, beforeRow)
        undoManager.redo()
        layout()
        XCTAssertEqual(editor.document, afterRow)

        window.makeFirstResponder(editor)
        editor.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertFalse(editor.editingSession.hasActiveTableSelection)
        editor.perform(.toggleInline(.strong))
        editor.insertText("X", replacementRange: editor.selectedRange)
        XCTAssertEqual(try table(), try XCTUnwrap(afterRow.blocks.compactMap { block -> MarkdownTable? in
            if case let .table(table) = block {
                return table
            }
            return nil
        }.first))
    }

    func testRichCellEditsPreserveStylesAndUseVisibleOffsets() throws {
        let attachment = MarkdownTableAttachment(table: MarkdownTable(
            alignments: [.right],
            header: MarkdownTableRow(cells: [MarkdownTableCell(content: [.strong([.text("bold")]), .text(" tail")])]),
            rows: []
        ))
        let storage = NSTextContentStorage()
        let provider = try XCTUnwrap(attachment.viewProvider(for: nil, location: storage.documentRange.location, textContainer: nil))
        let root = try XCTUnwrap(provider.view)
        let field = try XCTUnwrap(firstSubview(of: NSTextView.self, in: root))
        XCTAssertEqual(field.string, "bold tail")
        XCTAssertEqual(field.alignment, .right)
        XCTAssertEqual(field.attributedString().attribute(.markdownEditorStrong, at: 0, effectiveRange: nil) as? NSNumber, true)
        field.setSelectedRange(NSRange(location: 5, length: 4))
        field.insertText("ending", replacementRange: field.selectedRange())
        XCTAssertEqual(attachment.controller.table.header.cells[0].content, [.strong([.text("bold")]), .text(" ending")])
        XCTAssertEqual(attachment.controller.activeSelection?.range, NSRange(location: 11, length: 0))
    }

    func testAttachmentBoundsFollowCellGrowthRowsAndContainerWidth() throws {
        let attachment = MarkdownTableAttachment(table: MarkdownTable(
            alignments: [.left], header: MarkdownTableRow(cells: [MarkdownTableCell(content: [.text("A")])]), rows: []
        ))
        let storage = NSTextContentStorage()
        let location = storage.documentRange.location
        let container = NSTextContainer(size: NSSize(width: 100, height: 1000))
        let provider = try XCTUnwrap(attachment.viewProvider(for: nil, location: location, textContainer: container))
        func bounds() -> CGRect {
            provider.attachmentBounds(
                for: [:],
                location: location,
                textContainer: container,
                proposedLineFragment: CGRect(x: 0, y: 0, width: container.size.width, height: 1000),
                position: .zero
            )
        }
        let initial = bounds()
        attachment.controller.updateCell(at: .init(section: .header, column: 0), source: "A long sentence that wraps into multiple lines in a narrow table column")
        let grown = bounds()
        XCTAssertGreaterThan(grown.height, initial.height)
        XCTAssertEqual(provider.view?.frame.size, grown.size)
        attachment.controller.appendRow()
        let withRow = bounds()
        XCTAssertGreaterThan(withRow.height, grown.height)
        container.size.width = 300
        let widened = bounds()
        XCTAssertGreaterThan(widened.width, withRow.width)
        XCTAssertLessThan(widened.height, withRow.height)
    }

    func testAppKitViewProviderConstructsNativeGrid() throws {
        let attachment = MarkdownTableAttachment(table: makeTable())
        let contentStorage = NSTextContentStorage()
        let provider = try XCTUnwrap(
            attachment.viewProvider(
                for: nil,
                location: contentStorage.documentRange.location,
                textContainer: nil
            )
        )

        XCTAssertTrue(provider is MarkdownTableAttachmentViewProvider)
        XCTAssertNotNil(provider.view)
        XCTAssertTrue(provider.tracksTextAttachmentViewBounds)
    }

    func testAppKitGridUsesContentWidthsAndWrapsWithinTextContainer() throws {
        let table = MarkdownTable(
            alignments: [.left, .left],
            header: MarkdownTableRow(cells: [
                MarkdownTableCell(content: [.text("A")]),
                MarkdownTableCell(content: [.text("A substantially longer heading that needs wrapping")])
            ]),
            rows: [MarkdownTableRow(cells: [
                MarkdownTableCell(content: [.text("1")]),
                MarkdownTableCell(content: [.text("2")])
            ])]
        )
        let attachment = MarkdownTableAttachment(table: table)
        let contentStorage = NSTextContentStorage()
        let textContainer = NSTextContainer(size: NSSize(width: 180, height: 1000))
        let provider = try XCTUnwrap(
            attachment.viewProvider(
                for: nil,
                location: contentStorage.documentRange.location,
                textContainer: textContainer
            )
        )
        let rootView = try XCTUnwrap(provider.view)
        let gridView = try XCTUnwrap(firstSubview(of: NSGridView.self, in: rootView))
        rootView.frame.size = rootView.intrinsicContentSize
        rootView.layoutSubtreeIfNeeded()

        let firstWidth = gridView.column(at: 0).width
        let secondWidth = gridView.column(at: 1).width
        XCTAssertLessThanOrEqual(firstWidth + secondWidth, 180.001)
        XCTAssertGreaterThan(secondWidth, firstWidth)

        let shortField = try XCTUnwrap(gridView.cell(atColumnIndex: 0, rowIndex: 0).contentView as? NSTextView)
        let wrappingField = try XCTUnwrap(gridView.cell(atColumnIndex: 1, rowIndex: 0).contentView as? NSTextView)
        XCTAssertGreaterThan(wrappingField.intrinsicContentSize.height, shortField.intrinsicContentSize.height)
    }

    func testAppKitTextViewLaysOutEveryTableCell() throws {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 620, height: 300)
        textView.textContainerInset = NSSize(width: 16, height: 20)
        textView.document = MarkdownDocument(markdown: """
        | Format | Editing behavior |
        | --- | --- |
        | Strong | Bold text |
        | Link | A longer destination label that wraps when the available editor width cannot fit the complete cell content on one line |
        """)
        let window = NSWindow(
            contentRect: textView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        if let textLayoutManager = textView.textLayoutManager {
            textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        }
        textView.layoutSubtreeIfNeeded()

        let gridView = try XCTUnwrap(firstSubview(of: NSGridView.self, in: textView))
        let attachmentView = try XCTUnwrap(gridView.superview)
        XCTAssertEqual(gridView.numberOfColumns, 2)
        XCTAssertEqual(gridView.numberOfRows, 3)
        XCTAssertGreaterThanOrEqual(attachmentView.bounds.width, gridView.frame.maxX)
        XCTAssertGreaterThanOrEqual(attachmentView.bounds.height, gridView.frame.maxY)
        let cellFrames = (0 ..< gridView.numberOfRows).flatMap { row in
            (0 ..< gridView.numberOfColumns).map { column in
                gridView.cell(atColumnIndex: column, rowIndex: row).contentView?.frame ?? .zero
            }
        }
        XCTAssertEqual(Set(cellFrames.map(\.origin)).count, 6)
        XCTAssertTrue(cellFrames.allSatisfy { $0.width > 0 && $0.height > 0 })
    }

    func testAppKitReturnInsertsLineBreakInCell() throws {
        let attachment = MarkdownTableAttachment(table: makeTable())
        let contentStorage = NSTextContentStorage()
        let provider = try XCTUnwrap(
            attachment.viewProvider(
                for: nil,
                location: contentStorage.documentRange.location,
                textContainer: nil
            )
        )
        let rootView = try XCTUnwrap(provider.view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: rootView.intrinsicContentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = rootView
        window.makeKeyAndOrderFront(nil)
        let gridView = try XCTUnwrap(firstSubview(of: NSGridView.self, in: rootView))
        let firstCell = try XCTUnwrap(
            gridView.cell(atColumnIndex: 0, rowIndex: 0).contentView as? NSTextView
        )
        firstCell.setSelectedRange(NSRange(location: firstCell.string.utf16.count, length: 0))
        window.makeFirstResponder(firstCell)

        firstCell.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        XCTAssertTrue(window.firstResponder === firstCell)
        XCTAssertEqual(firstCell.string, "A\n")
        XCTAssertEqual(
            attachment.controller.table.header.cells[0].content,
            [.text("A"), .html("<br />")]
        )
    }

    #elseif canImport(UIKit)
    func testStableCellEditsSkipAttachmentFittingUntilRowHeightChanges() throws {
        let attachment = MarkdownTableAttachment(table: sizingTable())
        let storage = NSTextContentStorage()
        let container = NSTextContainer(size: CGSize(width: 240, height: 1000))
        let provider = try XCTUnwrap(attachment.viewProvider(for: nil, location: storage.documentRange.location, textContainer: container))
        let view = try XCTUnwrap(provider.view as? UIKitMarkdownTableGridView)
        let cell = try XCTUnwrap(subviews(of: UITextView.self, in: view).first { $0.accessibilityLabel == "Table row 1, column 1" })
        let initialResizeCount = view.attachmentResizeCount
        let initialHeight = view.frame.height

        for text in ["a", "ab", "abc", "a\nb"] {
            cell.text = text
            view.textViewDidChange(cell)
            XCTAssertEqual(view.attachmentResizeCount, initialResizeCount, "Unchanged column widths and row heights must skip full grid fitting")
        }

        cell.text = "a\nb\nc\nd\ne\nf\ng"
        view.textViewDidChange(cell)
        XCTAssertEqual(view.attachmentResizeCount, initialResizeCount + 1)
        XCTAssertGreaterThan(view.frame.height, initialHeight)
    }

    func testTableEditMenuTargetsItsCellAndSupportsUndo() throws {
        let editor = MarkdownTextView(usingTextLayoutManager: true)
        editor.frame = CGRect(x: 0, y: 0, width: 358, height: 600)
        let original = MarkdownDocument(markdown: "| A | B |\n| - | - |\n| a | b |")
        editor.document = original
        let window = UIWindow(frame: editor.frame)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(editor)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        func tableMenu(_ section: String = "Table", selection: NSRange = NSRange(location: 0, length: 0)) throws -> UIMenu {
            if let manager = editor.textLayoutManager {
                manager.ensureLayout(for: manager.documentRange)
            }
            editor.layoutIfNeeded()
            let cells = subviews(of: UITextView.self, in: editor).filter { $0 !== editor }
            let first = try XCTUnwrap(cells.first { $0.text == "A" })
            let second = try XCTUnwrap(cells.first { $0.text == "B" })
            first.becomeFirstResponder()
            let suggested = UIAction(title: "Copy") { _ in }
            let menu = try XCTUnwrap(second.delegate?.textView?(second, editMenuForTextIn: selection, suggestedActions: [suggested]))
            XCTAssertTrue(menu.children.contains { $0 === suggested })
            return try XCTUnwrap(menu.children.compactMap { $0 as? UIMenu }.first { $0.title == section })
        }
        func invoke(_ title: String, in menu: UIMenu) throws {
            let action = try XCTUnwrap(menu.children.compactMap { $0 as? UIAction }.first { $0.title == title })
            let button = UIButton(type: .system)
            button.addAction(action, for: .touchUpInside)
            button.sendActions(for: .touchUpInside)
        }
        let menu = try tableMenu()
        let deleteRow = try XCTUnwrap(menu.children.compactMap { $0 as? UIAction }.first { $0.title == "Delete row" })
        XCTAssertTrue(deleteRow.attributes.contains(.disabled))
        try invoke("Add column", in: menu)
        guard case let .table(table) = editor.document.blocks[0] else {
            return XCTFail("Missing table")
        }
        XCTAssertEqual(table.header.cells.map(\.content), [[.text("A")], [.text("B")], []])
        editor.undoManager?.undo()
        XCTAssertEqual(editor.document, original)
        try invoke("Add row", in: tableMenu())
        guard case let .table(expanded) = editor.document.blocks[0] else {
            return XCTFail("Missing table")
        }
        XCTAssertEqual(expanded.rows.count, 2)
        try invoke("Bold", in: tableMenu("Style", selection: NSRange(location: 0, length: 1)))
        guard case let .table(formatted) = editor.document.blocks[0] else {
            return XCTFail("Missing table")
        }
        XCTAssertEqual(formatted.header.cells[1].content, [.strong([.text("B")])])

    }

    func testUIKitHostedTableFormattingFocusGrowthAndUndo() throws {
        let editor = MarkdownTextView(usingTextLayoutManager: true)
        editor.frame = CGRect(x: 0, y: 0, width: 358, height: 600)
        editor.document = MarkdownDocument(markdown: "Before")
        let window = UIWindow(frame: editor.frame)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(editor)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.selectedRange = NSRange(location: 6, length: 0)
        editor.perform(.insertTable(columns: 2, bodyRows: 1))

        func layout() {
            if let manager = editor.textLayoutManager {
                manager.ensureLayout(for: manager.documentRange)
            }
            editor.layoutIfNeeded()
        }
        func firstCell() throws -> UITextView {
            layout()
            return try XCTUnwrap(subviews(of: UITextView.self, in: editor).first { $0 !== editor && $0.accessibilityLabel == "Table header, column 1" })
        }
        func table() throws -> MarkdownTable {
            try XCTUnwrap(editor.document.blocks.compactMap { block -> MarkdownTable? in
                if case let .table(table) = block {
                    return table
                }
                return nil
            }.first)
        }
        var cell = try firstCell()
        XCTAssertTrue(cell.isFirstResponder)
        XCTAssertEqual(cell.selectedRange, NSRange(location: 0, length: 0))
        cell.insertText("bold tail")
        cell.selectedRange = NSRange(location: 0, length: 4)
        editor.perform(.toggleInline(.strong))
        cell = try firstCell()
        XCTAssertTrue(cell.isFirstResponder)
        XCTAssertEqual(cell.selectedRange, NSRange(location: 0, length: 4))
        cell.selectedRange = NSRange(location: 5, length: 4)
        editor.perform(.toggleInline(.emphasis))
        cell = try firstCell()
        XCTAssertEqual(cell.text, "bold tail")
        XCTAssertEqual(cell.selectedRange, NSRange(location: 5, length: 4))
        XCTAssertEqual(try table().header.cells[0].content, [.strong([.text("bold")]), .text(" "), .emphasis([.text("tail")])])
        cell.selectedRange = NSRange(location: 9, length: 0)
        editor.perform(.toggleInline(.strong))
        cell.insertText("!")
        XCTAssertTrue(cell.isFirstResponder)
        XCTAssertEqual(cell.selectedRange, NSRange(location: 10, length: 0))
        XCTAssertEqual(cell.textStorage.attribute(.markdownEditorStrong, at: 9, effectiveRange: nil) as? NSNumber, true)

        let beforeRow = editor.document
        let undoManager = try XCTUnwrap(cell.undoManager)
        XCTAssertTrue(undoManager === editor.undoManager, "Cell undo must use the enclosing editor history")
        while undoManager.groupingLevel > 0 {
            undoManager.endUndoGrouping()
        }
        undoManager.removeAllActions()
        undoManager.beginUndoGrouping()
        editor.perform(.insertTableRow)
        undoManager.endUndoGrouping()
        layout()
        XCTAssertEqual(try table().rows.count, 2)
        XCTAssertTrue(subviews(of: UITextView.self, in: editor).contains { $0 !== editor && $0.isFirstResponder })
        let afterRow = editor.document
        undoManager.undo()
        XCTAssertTrue(undoManager.canRedo, "Undo must register redo before layout")
        XCTAssertTrue(editor.undoManager === undoManager, "Outer editor undo manager identity must remain stable")
        layout()
        XCTAssertTrue(undoManager.canRedo, "Nested cell layout must retain redo")
        XCTAssertEqual(editor.document, beforeRow)
        undoManager.redo()
        layout()
        XCTAssertEqual(editor.document, afterRow)

        cell = try firstCell()
        cell.becomeFirstResponder()
        cell.selectedRange = NSRange(location: cell.textStorage.length, length: 0)
        let row = try XCTUnwrap(cell.superview as? UIStackView)
        let grid = try XCTUnwrap(row.superview?.superview)
        let initialHeight = grid.bounds.height
        cell.insertText(String(repeating: " wrapping content", count: 12))
        layout()
        XCTAssertGreaterThan(grid.bounds.height, initialHeight)
        XCTAssertGreaterThanOrEqual(grid.bounds.height, grid.intrinsicContentSize.height)
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertFalse(editor.editingSession.hasActiveTableSelection)
    }

    func testUIKitViewProviderConstructsNativeGrid() throws {
        let attachment = MarkdownTableAttachment(table: makeTable())
        let contentStorage = NSTextContentStorage()
        let provider = try XCTUnwrap(
            attachment.viewProvider(
                for: nil,
                location: contentStorage.documentRange.location,
                textContainer: nil
            )
        )

        XCTAssertTrue(provider is MarkdownTableAttachmentViewProvider)
        XCTAssertNotNil(provider.view)
        XCTAssertTrue(provider.tracksTextAttachmentViewBounds)
    }

    func testUIKitGridMeasuresWrappedHeightBeforeAttachmentLayout() throws {
        let table = MarkdownTable(
            alignments: [.left, .left],
            header: MarkdownTableRow(cells: [
                MarkdownTableCell(content: [.text("Format")]),
                MarkdownTableCell(content: [.text("Editing behavior")])
            ]),
            rows: [
                MarkdownTableRow(cells: [
                    MarkdownTableCell(content: [.text("Strong")]),
                    MarkdownTableCell(content: [.text("Bold text")])
                ]),
                MarkdownTableRow(cells: [
                    MarkdownTableCell(content: [.text("Link")]),
                    MarkdownTableCell(content: [.text("A longer destination label that wraps when the available editor width cannot fit the complete cell content on one line")])
                ])
            ]
        )
        let attachment = MarkdownTableAttachment(table: table)
        let contentStorage = NSTextContentStorage()
        let textContainer = NSTextContainer(size: CGSize(width: 358, height: 1000))
        let provider = try XCTUnwrap(
            attachment.viewProvider(
                for: nil,
                location: contentStorage.documentRange.location,
                textContainer: textContainer
            )
        )
        let rootView = try XCTUnwrap(provider.view)
        rootView.bounds.size = rootView.intrinsicContentSize
        rootView.layoutIfNeeded()

        let cells = subviews(of: UITextView.self, in: rootView)
        XCTAssertEqual(cells.count, 6)
        let formatCell = try XCTUnwrap(cells.first { $0.text == "Format" })
        let wrappingCell = try XCTUnwrap(cells.first { $0.text.hasPrefix("A longer destination") })
        let wrappingRow = try XCTUnwrap(wrappingCell.superview as? UIStackView)
        XCTAssertGreaterThan(wrappingCell.bounds.width, formatCell.bounds.width)
        XCTAssertGreaterThan(wrappingCell.intrinsicContentSize.height, formatCell.intrinsicContentSize.height)
        XCTAssertEqual(
            wrappingCell.bounds.height,
            wrappingCell.intrinsicContentSize.height,
            accuracy: 0.001
        )
        XCTAssertEqual(wrappingRow.bounds.height, wrappingCell.bounds.height, accuracy: 0.001)
        XCTAssertGreaterThan(wrappingRow.bounds.height, formatCell.bounds.height)
        XCTAssertGreaterThan(rootView.intrinsicContentSize.height, formatCell.intrinsicContentSize.height * 3)
        XCTAssertEqual(rootView.bounds.height, rootView.intrinsicContentSize.height, accuracy: 0.001)
    }

    func testUIKitCellTypingKeepsNestedFocusAndSelection() throws {
        let attachment = MarkdownTableAttachment(table: makeTable())
        var reportedSelections: [MarkdownTableCellSelection?] = []
        attachment.controller.configureSelection(nil) { reportedSelections.append($0) }
        let contentStorage = NSTextContentStorage()
        let provider = try XCTUnwrap(
            attachment.viewProvider(
                for: nil,
                location: contentStorage.documentRange.location,
                textContainer: nil
            )
        )
        let rootView = try XCTUnwrap(provider.view)
        rootView.frame.size = rootView.intrinsicContentSize
        let window = UIWindow(frame: CGRect(origin: .zero, size: rootView.frame.size))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(rootView)
        window.makeKeyAndVisible()
        rootView.layoutIfNeeded()
        let cell = try XCTUnwrap(
            subviews(of: UITextView.self, in: rootView).first { $0.text == "A" }
        )
        cell.selectedRange = NSRange(location: cell.textStorage.length, length: 0)
        XCTAssertTrue(cell.becomeFirstResponder())

        cell.insertText("2")
        rootView.layoutIfNeeded()

        XCTAssertTrue(cell.isFirstResponder)
        XCTAssertEqual(cell.selectedRange, NSRange(location: 2, length: 0))
        XCTAssertEqual(attachment.controller.source(at: .init(section: .header, column: 0)), "A2")
        XCTAssertEqual(reportedSelections.compactMap(\.self).last?.range, cell.selectedRange)
    }

    func testUIKitReturnInsertsLineBreakInCell() throws {
        let attachment = MarkdownTableAttachment(table: makeTable())
        let contentStorage = NSTextContentStorage()
        let provider = try XCTUnwrap(
            attachment.viewProvider(
                for: nil,
                location: contentStorage.documentRange.location,
                textContainer: nil
            )
        )
        let rootView = try XCTUnwrap(provider.view)
        rootView.frame.size = rootView.intrinsicContentSize
        let window = UIWindow(frame: CGRect(origin: .zero, size: rootView.frame.size))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(rootView)
        window.makeKeyAndVisible()
        rootView.layoutIfNeeded()
        let firstCell = try XCTUnwrap(
            subviews(of: UITextView.self, in: rootView).first { $0.text == "A" }
        )
        firstCell.selectedRange = NSRange(location: firstCell.textStorage.length, length: 0)
        XCTAssertTrue(firstCell.becomeFirstResponder())

        firstCell.insertText("\n")

        XCTAssertTrue(firstCell.isFirstResponder)
        XCTAssertEqual(firstCell.text, "A\n")
        XCTAssertEqual(firstCell.selectedRange, NSRange(location: 2, length: 0))
        XCTAssertEqual(
            attachment.controller.table.header.cells[0].content,
            [.text("A"), .html("<br />")]
        )
    }
    #endif

    private func sizingTable() -> MarkdownTable {
        MarkdownTable(
            alignments: [.left, .left],
            header: .init(cells: [.init(content: [.text("A wide header")]), .init(content: [.text("Another wide header")])]),
            rows: [.init(cells: [.init(content: [.text("a")]), .init(content: [.text("a"), .html("<br />"), .text("b"), .html("<br />"), .text("c")])])]
        )
    }

    private func makeTable() -> MarkdownTable {
        MarkdownTable(
            alignments: [.left, .right],
            header: MarkdownTableRow(cells: [
                MarkdownTableCell(content: [.text("A")]),
                MarkdownTableCell(content: [.text("B")])
            ]),
            rows: [MarkdownTableRow(cells: [
                MarkdownTableCell(content: [.text("1")]),
                MarkdownTableCell(content: [.text("2")])
            ])]
        )
    }

    #if canImport(AppKit)
    private func firstSubview<View: NSView>(of type: View.Type, in rootView: NSView) -> View? {
        if let view = rootView as? View {
            return view
        }
        return rootView.subviews.lazy.compactMap { self.firstSubview(of: type, in: $0) }.first
    }

    #elseif canImport(UIKit)
    private func subviews<View: UIView>(of type: View.Type, in rootView: UIView) -> [View] {
        let current = (rootView as? View).map { [$0] } ?? []
        return current + rootView.subviews.flatMap { self.subviews(of: type, in: $0) }
    }

    #endif

}
