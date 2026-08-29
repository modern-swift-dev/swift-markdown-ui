@testable import MarkdownUIEditor
import XCTest

final class MarkdownEditingTests: XCTestCase {
    func testInlineStyleCommandsToggleEveryStyle() {
        let styles: [(MarkdownInlineStyle, MarkdownInline)] = [
            (.emphasis, .emphasis([.text("word")])),
            (.strong, .strong([.text("word")])),
            (.strikethrough, .strikethrough([.text("word")])),
            (.code, .code("word"))
        ]

        for (style, expected) in styles {
            let document = paragraph("word")
            let selection = MarkdownLogicalSelection(path: .block(0), utf16Length: 4)
            let applied = MarkdownEditingEngine.apply(.toggleInline(style), to: document, selection: selection)
            XCTAssertEqual(applied.document.blocks, [.paragraph([expected])])
            XCTAssertEqual(applied.selection, selection)

            let removed = MarkdownEditingEngine.apply(.toggleInline(style), to: applied.document, selection: selection)
            XCTAssertEqual(removed.document, document)
        }
    }

    func testAdjacentStylesAndBoundaryWhitespaceRoundTrip() {
        for style in [MarkdownInlineStyle.strong, .emphasis, .strikethrough] {
            let first = MarkdownEditingEngine.apply(
                .toggleInline(style),
                to: paragraph("helloworld"),
                selection: .init(path: .block(0), utf16Length: 5)
            )
            let second = MarkdownEditingEngine.apply(
                .toggleInline(style),
                to: first.document,
                selection: .init(path: .block(0), utf16Offset: 5, utf16Length: 5)
            )
            XCTAssertEqual(MarkdownDocument(markdown: second.document.markdown), second.document)
            let whitespace = MarkdownEditingEngine.apply(
                .toggleInline(style),
                to: paragraph("hello world"),
                selection: .init(path: .block(0), utf16Length: 6)
            )
            XCTAssertEqual(MarkdownDocument(markdown: whitespace.document.markdown), whitespace.document)
        }
    }

    func testStyleRemovalFindsNestedWrappers() {
        let document = MarkdownDocument(blocks: [.paragraph([.emphasis([.strong([.text("hello")])])])])
        let result = MarkdownEditingEngine.apply(
            .toggleInline(.strong),
            to: document,
            selection: .init(path: .block(0), utf16Length: 5)
        )
        XCTAssertEqual(result.document.blocks, [.paragraph([.emphasis([.text("hello")])])])
        XCTAssertEqual(MarkdownDocument(markdown: result.document.markdown), result.document)
    }

    func testChangingLinkReplacesExistingDestination() {
        let document = MarkdownDocument(markdown: "[hello](/old)")
        let result = MarkdownEditingEngine.apply(
            .setLink(destination: "/new", title: nil),
            to: document,
            selection: .init(path: .block(0), utf16Length: 5)
        )
        XCTAssertEqual(result.document, MarkdownDocument(markdown: "[hello](/new)"))
        XCTAssertEqual(MarkdownDocument(markdown: result.document.markdown), result.document)
    }

    func testFormattingAfterImageUsesAttachmentWidth() {
        let document = MarkdownDocument(markdown: "![long alt](image.png)hello world")
        let result = MarkdownEditingEngine.apply(
            .toggleInline(.strong),
            to: document,
            selection: .init(path: .block(0), utf16Offset: 1, utf16Length: 5)
        )
        XCTAssertEqual(result.document, MarkdownDocument(markdown: "![long alt](image.png)**hello** world"))
    }

    func testInlineCodeCanBePartiallyUnformatted() {
        let document = MarkdownDocument(markdown: "`hello world`")
        let result = MarkdownEditingEngine.apply(
            .toggleInline(.code),
            to: document,
            selection: .init(path: .block(0), utf16Offset: 6, utf16Length: 5)
        )
        XCTAssertEqual(result.document.blocks, [.paragraph([.code("hello "), .text("world")])])
        XCTAssertEqual(MarkdownDocument(markdown: result.document.markdown), result.document)
    }

    func testSerializationNormalizesNativeFormattingRuns() {
        let document = MarkdownDocument(blocks: [.paragraph([
            .strong([.text("hello")]), .strong([.text(" world ")]), .text("tail")
        ])])
        XCTAssertEqual(MarkdownDocument(markdown: document.markdown), MarkdownDocument(markdown: "**hello world** tail"))
    }

    func testBlockConversionCoversParagraphHeadingsQuoteAndCode() {
        let selection = MarkdownLogicalSelection(path: .block(0), utf16Offset: 1)
        let heading = MarkdownEditingEngine.apply(.convertBlock(.heading(.six)), to: paragraph("value"), selection: selection)
        XCTAssertEqual(heading.document.blocks, [.heading(level: .six, content: [.text("value")])])

        let paragraph = MarkdownEditingEngine.apply(.convertBlock(.paragraph), to: heading.document, selection: selection)
        XCTAssertEqual(paragraph.document, self.paragraph("value"))

        let quote = MarkdownEditingEngine.apply(.convertBlock(.blockquote), to: paragraph.document, selection: selection)
        XCTAssertEqual(quote.document.blocks, [.blockquote([.paragraph([.text("value")])])])
        XCTAssertEqual(quote.selection.path, .blockquote(parent: .block(0), child: 0))

        let code = MarkdownEditingEngine.apply(.convertBlock(.code(info: "swift")), to: paragraph.document, selection: selection)
        XCTAssertEqual(code.document.blocks, [.codeBlock(info: "swift", content: "value")])
    }

    func testListConversionsAndTaskToggle() {
        let selection = MarkdownLogicalSelection(path: .block(0), utf16Offset: 2)
        let task = MarkdownEditingEngine.apply(.convertList(.task), to: paragraph("todo"), selection: selection)
        let itemPath = MarkdownLogicalPath.listItemBlock(list: .block(0), item: 0, block: 0)
        XCTAssertEqual(task.selection.path, itemPath)
        XCTAssertEqual(task.selection.utf16Offset, 2)

        let checked = MarkdownEditingEngine.apply(.toggleTask, to: task.document, selection: task.selection)
        XCTAssertEqual(list(in: checked.document).items[0].taskState, .checked)

        let ordered = MarkdownEditingEngine.apply(.convertList(.ordered(start: 4)), to: checked.document, selection: checked.selection)
        XCTAssertEqual(list(in: ordered.document).kind, .ordered(start: 4))
        XCTAssertNil(list(in: ordered.document).items[0].taskState)

        let unordered = MarkdownEditingEngine.apply(.convertList(.unordered), to: ordered.document, selection: ordered.selection)
        XCTAssertEqual(list(in: unordered.document).kind, .unordered)
    }

    func testIndentAndOutdentNestedListRestorePath() {
        let document = MarkdownDocument(blocks: [
            .list(MarkdownList(kind: .unordered, isTight: true, items: [
                MarkdownListItem(blocks: [.paragraph([.text("first")])]),
                MarkdownListItem(blocks: [.paragraph([.text("second")])])
            ]))
        ])
        let selection = MarkdownLogicalSelection(
            path: .listItemBlock(list: .block(0), item: 1, block: 0),
            utf16Offset: 3
        )

        let indented = MarkdownEditingEngine.apply(.indent, to: document, selection: selection)
        let nestedListPath = MarkdownLogicalPath.listItemBlock(list: .block(0), item: 0, block: 1)
        XCTAssertEqual(indented.selection.path, .listItemBlock(list: nestedListPath, item: 0, block: 0))
        XCTAssertEqual(list(in: indented.document).items.count, 1)

        let outdented = MarkdownEditingEngine.apply(.outdent, to: indented.document, selection: indented.selection)
        XCTAssertEqual(outdented.document, document)
        XCTAssertEqual(outdented.selection.path, selection.path)
        XCTAssertEqual(outdented.selection.utf16Offset, 3)
    }

    func testLinkCommandsAndImageInsertion() {
        let selection = MarkdownLogicalSelection(path: .block(0), utf16Offset: 1, utf16Length: 3)
        let linked = MarkdownEditingEngine.apply(
            .setLink(destination: "/target", title: "Title"),
            to: paragraph("hello"),
            selection: selection
        )
        XCTAssertEqual(linked.document.blocks, [
            .paragraph([.text("h"), .link(destination: "/target", title: "Title", children: [.text("ell")]), .text("o")])
        ])
        let unlinked = MarkdownEditingEngine.apply(.removeLink, to: linked.document, selection: selection)
        XCTAssertEqual(unlinked.document, paragraph("hello"))

        let image = MarkdownEditingEngine.apply(
            .insertImage(source: "image.png", title: nil, alt: "cat"),
            to: paragraph("hello"),
            selection: selection
        )
        XCTAssertEqual(image.document.blocks, [
            .paragraph([.text("h"), .image(source: "image.png", title: nil, children: [.text("cat")]), .text("o")])
        ])
        XCTAssertEqual(image.selection.utf16Offset, 2)
        XCTAssertEqual(image.selection.utf16Length, 0)
    }

    func testStructuralInsertionsRestoreSelectionToNewBlock() {
        let selection = MarkdownLogicalSelection(path: .block(0), utf16Offset: 1)
        let breakResult = MarkdownEditingEngine.apply(.insertThematicBreak, to: paragraph("a"), selection: selection)
        XCTAssertEqual(breakResult.document.blocks, [.paragraph([.text("a")]), .thematicBreak])
        XCTAssertEqual(breakResult.selection, MarkdownLogicalSelection(path: .block(1)))

        let tableResult = MarkdownEditingEngine.apply(.insertTable(columns: 2, bodyRows: 1), to: paragraph("a"), selection: selection)
        guard case let .table(table) = tableResult.document.blocks.last else {
            return XCTFail("Expected table")
        }
        XCTAssertEqual(table.alignments, [.none, .none])
        XCTAssertEqual(table.header.cells.count, 2)
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(tableResult.selection.path, .tableCell(table: .block(1), row: 0, column: 0))
    }

    func testTableRowCommandsAndAlignment() {
        let document = tableDocument()
        let selection = MarkdownLogicalSelection(path: .tableCell(table: .block(0), row: 1, column: 0))

        let inserted = MarkdownEditingEngine.apply(.insertTableRow, to: document, selection: selection)
        XCTAssertEqual(table(in: inserted.document).rows.count, 3)
        XCTAssertEqual(inserted.selection.path, .tableCell(table: .block(0), row: 2, column: 0))

        let moved = MarkdownEditingEngine.apply(.moveTableRow(.forward), to: document, selection: selection)
        XCTAssertEqual(cellText(table(in: moved.document).rows[1].cells[0]), "a")
        XCTAssertEqual(moved.selection.path, .tableCell(table: .block(0), row: 2, column: 0))

        let aligned = MarkdownEditingEngine.apply(.setTableColumnAlignment(.right), to: document, selection: selection)
        XCTAssertEqual(table(in: aligned.document).alignments[0], .right)

        let deleted = MarkdownEditingEngine.apply(.deleteTableRow, to: document, selection: selection)
        XCTAssertEqual(table(in: deleted.document).rows.count, 1)
    }

    func testTableColumnCommandsRestoreSelectedColumn() {
        let document = tableDocument()
        let selection = MarkdownLogicalSelection(path: .tableCell(table: .block(0), row: 1, column: 0))

        let inserted = MarkdownEditingEngine.apply(.insertTableColumn, to: document, selection: selection)
        XCTAssertEqual(table(in: inserted.document).alignments.count, 3)
        XCTAssertEqual(inserted.selection.path, .tableCell(table: .block(0), row: 1, column: 1))

        let moved = MarkdownEditingEngine.apply(.moveTableColumn(.forward), to: document, selection: selection)
        XCTAssertEqual(cellText(table(in: moved.document).header.cells[1]), "H1")
        XCTAssertEqual(moved.selection.path, .tableCell(table: .block(0), row: 1, column: 1))

        let deleted = MarkdownEditingEngine.apply(.deleteTableColumn, to: document, selection: selection)
        XCTAssertEqual(table(in: deleted.document).alignments.count, 1)
        XCTAssertEqual(deleted.selection.path, .tableCell(table: .block(0), row: 1, column: 0))
    }

    func testNestedBlockquoteAndTableCellPaths() {
        let quote = MarkdownDocument(blocks: [.blockquote([.paragraph([.text("inside")])])])
        let quoteSelection = MarkdownLogicalSelection(
            path: .blockquote(parent: .block(0), child: 0),
            utf16Length: 6
        )
        let strong = MarkdownEditingEngine.apply(.toggleInline(.strong), to: quote, selection: quoteSelection)
        XCTAssertEqual(strong.document.blocks, [.blockquote([.paragraph([.strong([.text("inside")])])])])

        let tableDocument = tableDocument()
        let cellSelection = MarkdownLogicalSelection(
            path: .tableCell(table: .block(0), row: 1, column: 0),
            utf16Length: 1
        )
        let emphasis = MarkdownEditingEngine.apply(.toggleInline(.emphasis), to: tableDocument, selection: cellSelection)
        XCTAssertEqual(table(in: emphasis.document).rows[0].cells[0].content, [.emphasis([.text("a")])])
    }

    func testInvalidPathsAndUTF16RangesAreNoOps() {
        let document = paragraph("A👩🏽‍💻B")
        let invalidPath = MarkdownLogicalSelection(path: .block(2), utf16Length: 1)
        XCTAssertEqual(
            MarkdownEditingEngine.apply(.toggleInline(.strong), to: document, selection: invalidPath),
            MarkdownEditingResult(document: document, selection: invalidPath)
        )

        let splitGrapheme = MarkdownLogicalSelection(path: .block(0), utf16Offset: 2, utf16Length: 1)
        XCTAssertEqual(
            MarkdownEditingEngine.apply(.toggleInline(.strong), to: document, selection: splitGrapheme),
            MarkdownEditingResult(document: document, selection: splitGrapheme)
        )

        let outOfBounds = MarkdownLogicalSelection(path: .block(0), utf16Offset: 50, utf16Length: 1)
        XCTAssertEqual(
            MarkdownEditingEngine.apply(.setLink(destination: "/", title: nil), to: document, selection: outOfBounds),
            MarkdownEditingResult(document: document, selection: outOfBounds)
        )

        XCTAssertEqual(
            MarkdownEditingEngine.apply(.insertThematicBreak, to: document, selection: outOfBounds),
            MarkdownEditingResult(document: document, selection: outOfBounds)
        )
    }

    private func paragraph(_ text: String) -> MarkdownDocument {
        MarkdownDocument(blocks: [.paragraph([.text(text)])])
    }

    private func list(in document: MarkdownDocument) -> MarkdownList {
        guard case let .list(list) = document.blocks[0] else {
            fatalError("Expected list")
        }
        return list
    }

    private func table(in document: MarkdownDocument) -> MarkdownTable {
        guard case let .table(table) = document.blocks[0] else {
            fatalError("Expected table")
        }
        return table
    }

    private func tableDocument() -> MarkdownDocument {
        MarkdownDocument(blocks: [.table(MarkdownTable(
            alignments: [.left, .right],
            header: MarkdownTableRow(cells: [cell("H1"), cell("H2")]),
            rows: [
                MarkdownTableRow(cells: [cell("a"), cell("b")]),
                MarkdownTableRow(cells: [cell("c"), cell("d")])
            ]
        ))])
    }

    private func cell(_ text: String) -> MarkdownTableCell {
        MarkdownTableCell(content: [.text(text)])
    }

    private func cellText(_ cell: MarkdownTableCell) -> String {
        guard case let .text(text) = cell.content.first else {
            return ""
        }
        return text
    }
}
