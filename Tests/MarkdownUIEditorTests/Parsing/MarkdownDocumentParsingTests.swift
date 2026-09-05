@testable import MarkdownUIEditor
import XCTest

final class MarkdownDocumentParsingTests: XCTestCase {
    func testComprehensiveGFMRoundTripIsSemanticallyStable() {
        let source = #"""
        # Héllø 👩🏽‍💻

        A paragraph with *emphasis*, **strong**, ~~removed~~, `code`,
        a hard break, [a link](https://example.com/a "Link title"),
        ![alt text](image.png 'Image title'), and www.example.com.

        > Quoted text
        >
        > 1. nested one
        > 2. nested two

        - ordinary item
        - [ ] incomplete task
        - [x] completed task
        - ordinary item after tasks

        3. ordered item
        4. another ordered item

        ```swift linenos
        let greeting = "こんにちは"
        ```

        | Name | Value | Notes |
        | :--- | ---: | :---: |
        | alpha | 1 | *first* |
        | beta | 2 | `second` |

        <section data-kind="raw">
        raw HTML stays raw
        </section>

        Inline <kbd>HTML</kbd> remains inline.

        ---
        """#

        assertSemanticRoundTrip(source)
    }

    func testLooseNestedListsRoundTrip() {
        let source = """
        - first paragraph

          second paragraph

          - nested
          - [x] nested task

        - final
        """

        assertSemanticRoundTrip(source)
    }

    func testPunctuationAdjacentFormattingPreservesEverySelectionOnExport() {
        for text in ["a.b", "a!b", "a_b", "a\\b", "hello (world)", "é。文", "👩🏽‍💻.文", "e\u{301}.b"] {
            for style in [MarkdownInlineStyle.emphasis, .strong, .strikethrough] {
                let boundaries = text.indices.map { $0.utf16Offset(in: text) } + [text.utf16.count]
                for (index, start) in boundaries.dropLast().enumerated() {
                    for end in boundaries.dropFirst(index + 1) {
                        let result = MarkdownEditingEngine.apply(
                            .toggleInline(style),
                            to: MarkdownDocument(blocks: [.paragraph([.text(text)])]),
                            selection: .init(path: .block(0), utf16Offset: start, utf16Length: end - start)
                        ).document
                        XCTAssertEqual(MarkdownDocument(markdown: result.markdown), result, "\(text), \(style), \(start)..<\(end): \(result.markdown)")
                    }
                }
            }
        }
    }

    func testFormattingBesideCodeAndLinksKeepsItsBoundaries() {
        for content: [MarkdownInline] in [
            [.text("a"), .strong([.code("code")]), .text("b")],
            [.text("é"), .emphasis([.link(destination: "/", title: nil, children: [.text("link")])]), .text("文")],
            [.text("a"), .strong([.text(".")]), .text("b"), .emphasis([.text("!")]), .text("c")]
        ] {
            let document = MarkdownDocument(blocks: [.paragraph(content)])
            XCTAssertEqual(MarkdownDocument(markdown: document.markdown), document, document.markdown)
        }
    }

    func testLinkAndImageTitlesArePreserved() {
        let document = MarkdownDocument(markdown: #"[link](/target "link title") ![alt](/image "image title")"#)

        guard case let .paragraph(content) = document.blocks.first else {
            return XCTFail("Expected a paragraph")
        }

        XCTAssertTrue(content.contains(.link(
            destination: "/target",
            title: "link title",
            children: [.text("link")]
        )))
        XCTAssertTrue(content.contains(.image(
            source: "/image",
            title: "image title",
            children: [.text("alt")]
        )))
        XCTAssertEqual(MarkdownDocument(markdown: document.markdown), document)
    }

    func testTableSeparatesHeaderAndBodyRows() {
        let document = MarkdownDocument(markdown: """
        | Left | Center | Right | None |
        | :--- | :----: | ----: | ---- |
        | a | b | c | d |
        """)

        guard case let .table(table) = document.blocks.first else {
            return XCTFail("Expected a table")
        }

        XCTAssertEqual(table.alignments, [.left, .center, .right, .none])
        XCTAssertEqual(table.header.cells.count, 4)
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(MarkdownDocument(markdown: document.markdown), document)
    }

    func testMixedTaskAndOrdinaryItemsStayInOneList() {
        let document = MarkdownDocument(markdown: """
        - ordinary
        - [ ] todo
        - [x] done
        - still ordinary
        """)

        guard case let .list(list) = document.blocks.first else {
            return XCTFail("Expected a list")
        }

        XCTAssertEqual(list.items.map(\.taskState), [nil, .unchecked, .checked, nil])
        XCTAssertEqual(MarkdownDocument(markdown: document.markdown), document)
    }

    func testEmptyOrderedListItemRoundTrips() {
        let document = MarkdownDocument(blocks: [
            .list(MarkdownList(
                kind: .ordered(start: 1),
                isTight: true,
                items: [
                    MarkdownListItem(blocks: [.paragraph([.text("first")])]),
                    MarkdownListItem(blocks: [.paragraph([])]),
                    MarkdownListItem(blocks: [.paragraph([.text("third")])])
                ]
            ))
        ])

        XCTAssertEqual(MarkdownDocument(markdown: document.markdown), document, document.markdown)
    }

    func testEmptyUnorderedListItemRoundTrips() {
        let document = MarkdownDocument(blocks: [
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [
                    MarkdownListItem(blocks: [.paragraph([.text("first")])]),
                    MarkdownListItem(blocks: [.paragraph([])])
                ]
            ))
        ])

        XCTAssertEqual(MarkdownDocument(markdown: document.markdown), document, document.markdown)
    }

    func testEmptyTaskListItemRoundTrips() {
        let document = MarkdownDocument(blocks: [
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [
                    MarkdownListItem(taskState: .checked, blocks: [.paragraph([.text("done")])]),
                    MarkdownListItem(taskState: .unchecked, blocks: [.paragraph([])])
                ]
            ))
        ])

        XCTAssertEqual(MarkdownDocument(markdown: document.markdown), document, document.markdown)
    }

    func testProgrammaticallyBuiltDocumentRoundTrips() {
        let document = MarkdownDocument(blocks: [
            .heading(level: .six, content: [.text("Small")]),
            .paragraph([
                .link(destination: "https://example.com", title: "Example", children: [.text("link")]),
                .text(" and "),
                .image(source: "asset.png", title: "Asset", children: [.text("alt")])
            ]),
            .codeBlock(info: "swift custom-info", content: "let value = \"🧪\"\n"),
            .html("<details>raw</details>\n"),
            .thematicBreak
        ])

        XCTAssertEqual(MarkdownDocument(markdown: document.markdown), document)
    }

    private func assertSemanticRoundTrip(_ source: String, file: StaticString = #filePath, line: UInt = #line) {
        let parsed = MarkdownDocument(markdown: source)
        let reparsed = MarkdownDocument(markdown: parsed.markdown)
        XCTAssertEqual(reparsed, parsed, file: file, line: line)
    }
}
