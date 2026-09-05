@testable import MarkdownUIEditor
import XCTest

final class MarkdownDocumentParsingTests: XCTestCase {
    func testTaskMarkersUseItemOffsetAndOnlyTheirOwnCompletionMarker() {
        let samples: [(String, [MarkdownTaskState?])] = [
            ("1. [ ] todo contains [x] text", [.unchecked]),
            ("> 1. [ ] todo", [.unchecked]),
            ("> - [x] done", [.checked]),
            ("> > - [X] café 😀", [.checked]),
            ("- outer\n  > 1. [ ] todo\n  >    continuation", [nil, .unchecked]),
            ("> -\t[ ]\ttodo\r\n> - [x] done\r\n", [.unchecked, .checked]),
            ("> - outer\n>   - [x] inner", [nil, .checked]),
            ("> - [ ] [link](https://example.com)", [.unchecked]),
            ("> -\n>   [ ] todo", [.unchecked]),
            ("> - [ ]\n> - [X] done", [.unchecked, .checked])
        ]
        for (source, expected) in samples {
            let document = MarkdownDocument(markdown: source)
            XCTAssertEqual(taskStates(in: document.blocks), expected, source)
            XCTAssertEqual(taskStates(in: MarkdownDocument(markdown: document.markdown).blocks), expected, source)
        }
        XCTAssertEqual(MarkdownDocument(markdown: "> > - [X] café 😀").blocks, [
            .blockquote([.blockquote([
                .list(.init(kind: .unordered, isTight: true, items: [
                    .init(taskState: .checked, blocks: [.paragraph([.text("café 😀")])])
                ]))
            ])])
        ])
    }

    func testTaskDetectionPreservesEscapesCodeLinksAndLaterParagraphs() {
        let literalSamples: [(String, [MarkdownInline])] = [
            (#"\[ ] escaped"#, [.text("[ ] escaped")]),
            ("`[ ] code`", [.code("[ ] code")]),
            ("[ ](https://example.com)", [.link(destination: "https://example.com", title: nil, children: [.text(" ")])]),
            ("&#91; ] entity", [.text("[ ] entity")])
        ]
        for prefix in ["", "> ", "> > "] {
            for (source, expected) in literalSamples {
                var blocks = MarkdownDocument(markdown: prefix + "- " + source).blocks
                for _ in prefix.filter({ $0 == ">" }) {
                    guard case let .blockquote(children) = blocks.first else {
                        return XCTFail("Expected blockquote: \(prefix + source)")
                    }
                    blocks = children
                }
                XCTAssertEqual(blocks, [.list(.init(kind: .unordered, isTight: true, items: [
                    .init(blocks: [.paragraph(expected)])
                ]))], source)
            }
        }
        let blockSamples: [(String, [MarkdownBlock])] = [
            ("> - normal\n>\n>   [ ] second paragraph", [
                .paragraph([.text("normal")]), .paragraph([.text("[ ] second paragraph")])
            ]),
            ("> -     [ ] code", [.codeBlock(info: nil, content: "[ ] code\n")])
        ]
        for (source, expected) in blockSamples {
            let document = MarkdownDocument(markdown: source)
            XCTAssertEqual(taskStates(in: document.blocks), [nil], source)
            guard case let .blockquote(children) = document.blocks.first,
                  case let .list(list) = children.first else {
                return XCTFail("Expected quoted list: \(source)")
            }
            XCTAssertEqual(list.items.first?.blocks, expected, source)
        }
    }

    private func taskStates(in blocks: [MarkdownBlock]) -> [MarkdownTaskState?] {
        blocks.flatMap { block -> [MarkdownTaskState?] in
            switch block {
                case let .list(list):
                    list.items.flatMap { [$0.taskState] + taskStates(in: $0.blocks) }
                case let .blockquote(children):
                    taskStates(in: children)
                default:
                    []
            }
        }
    }

    func testTaskExtensionIsIsolatedAcrossConcurrentParses() {
        let sources = ["> - [ ] todo contains [x] text", "> > 1. [X] café 😀"]
        let expected = sources.map { MarkdownDocument(markdown: $0) }
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            XCTAssertEqual(MarkdownDocument(markdown: sources[index % sources.count]), expected[index % sources.count])
        }
    }

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
