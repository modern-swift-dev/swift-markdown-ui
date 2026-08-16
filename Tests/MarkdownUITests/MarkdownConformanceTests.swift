import Foundation
@testable import MarkdownUI
import XCTest

final class MarkdownConformanceTests: XCTestCase {
    private struct ASTFixture {
        let name: String
        let markdown: String
        let expectedBlocks: [BlockNode]
    }

    func testSupportedBlocksAndInlinesMatchTypedFixtures() {
        let fixtures: [ASTFixture] = [
            .init(
                name: "heading, inline formatting, blockquote, and fenced code",
                markdown: """
                # Heading *em* **strong** ~~old~~ `code` [site](https://example.com/a?x=1&y=2) ![logo](images/logo.png)

                > quote
                >
                > - child

                ---

                ```swift
                let value = 42
                ```
                """,
                expectedBlocks: [
                    .heading(
                        level: 1,
                        content: [
                            .text("Heading "),
                            .emphasis(children: [.text("em")]),
                            .text(" "),
                            .strong(children: [.text("strong")]),
                            .text(" "),
                            .strikethrough(children: [.text("old")]),
                            .text(" "),
                            .code("code"),
                            .text(" "),
                            .link(
                                destination: "https://example.com/a?x=1&y=2",
                                children: [.text("site")]
                            ),
                            .text(" "),
                            .image(source: "images/logo.png", children: [.text("logo")])
                        ]
                    ),
                    .blockquote(
                        children: [
                            .paragraph(content: [.text("quote")]),
                            .bulletedList(
                                isTight: true,
                                items: [.init(children: [.paragraph(content: [.text("child")])])]
                            )
                        ]
                    ),
                    .thematicBreak,
                    .codeBlock(fenceInfo: "swift", content: "let value = 42\n")
                ]
            ),
            .init(
                name: "all list kinds preserve tightness, start, and task completion",
                markdown: """
                - bullet

                3. three
                4. four

                - [ ] todo
                - [x] done
                """,
                expectedBlocks: [
                    .bulletedList(
                        isTight: true,
                        items: [.init(children: [.paragraph(content: [.text("bullet")])])]
                    ),
                    .numberedList(
                        isTight: true,
                        start: 3,
                        items: [
                            .init(children: [.paragraph(content: [.text("three")])]),
                            .init(children: [.paragraph(content: [.text("four")])])
                        ]
                    ),
                    .taskList(
                        isTight: true,
                        items: [
                            .init(isCompleted: false, children: [.paragraph(content: [.text("todo")])]),
                            .init(isCompleted: true, children: [.paragraph(content: [.text("done")])])
                        ]
                    )
                ]
            ),
            .init(
                name: "GFM table alignment and inline cells",
                markdown: """
                | Left | Center | Right |
                | :--- | :----: | ----: |
                | *a* | `b` | ~~c~~ |
                """,
                expectedBlocks: [
                    .table(
                        columnAlignments: [.left, .center, .right],
                        rows: [
                            .init(cells: [
                                .init(content: [.text("Left")]),
                                .init(content: [.text("Center")]),
                                .init(content: [.text("Right")])
                            ]),
                            .init(cells: [
                                .init(content: [.emphasis(children: [.text("a")])]),
                                .init(content: [.code("b")]),
                                .init(content: [.strikethrough(children: [.text("c")])])
                            ])
                        ]
                    )
                ]
            ),
            .init(
                name: "Unicode, nonbreaking spaces, soft breaks, and hard breaks",
                markdown: "café\u{00A0}☕\nnext  \nline",
                expectedBlocks: [
                    .paragraph(
                        content: [
                            .text("café\u{00A0}☕"),
                            .softBreak,
                            .text("next"),
                            .lineBreak,
                            .text("line")
                        ]
                    )
                ]
            ),
            .init(
                name: "malformed link preserves its prefix and autolinks a bare URL",
                markdown: "before [broken](https://example.com",
                expectedBlocks: [
                    .paragraph(
                        content: [
                            .text("before [broken]("),
                            .link(
                                destination: "https://example.com",
                                children: [.text("https://example.com")]
                            )
                        ]
                    )
                ]
            ),
            .init(
                name: "URL destinations and image alt text",
                markdown: "Visit [query](https://example.com/a?x=1&y=2) and ![alt text](images/pic.png).",
                expectedBlocks: [
                    .paragraph(
                        content: [
                            .text("Visit "),
                            .link(
                                destination: "https://example.com/a?x=1&y=2",
                                children: [.text("query")]
                            ),
                            .text(" and "),
                            .image(source: "images/pic.png", children: [.text("alt text")]),
                            .text(".")
                        ]
                    )
                ]
            )
        ]

        for fixture in fixtures {
            XCTAssertEqual(
                MarkdownContent(fixture.markdown),
                MarkdownContent(blocks: fixture.expectedBlocks),
                fixture.name
            )
        }
    }

    func testTagfilterAndOrdinaryHTMLHaveExplicitRenderedSemantics() {
        let content = MarkdownContent("<script>alert(1)</script>\n\n<span>safe</span>")

        XCTAssertEqual(
            content,
            MarkdownContent(
                blocks: [
                    .htmlBlock(content: "<script>alert(1)</script>\n"),
                    .paragraph(
                        content: [
                            .html("<span>"),
                            .text("safe"),
                            .html("</span>")
                        ]
                    )
                ]
            )
        )
        XCTAssertEqual(
            content.renderHTML(),
            "<!-- raw HTML omitted -->\n<p><!-- raw HTML omitted -->safe<!-- raw HTML omitted --></p>\n"
        )
    }

    func testSerializationNormalizesASTToCommonMark() {
        let content = MarkdownContent(
            blocks: [
                .paragraph(
                    content: [
                        .text("Hello "),
                        .link(destination: "https://example.com", children: [.text("link")]),
                        .text("!")
                    ]
                ),
                .codeBlock(fenceInfo: "swift", content: "let n = 1\n")
            ]
        )

        XCTAssertEqual(
            content.renderMarkdown(),
            """
            Hello [link](https://example.com)\\!

            ``` swift
            let n = 1
            ```
            """
        )
        XCTAssertEqual(MarkdownContent(content.renderMarkdown()), content)
    }
}
