import Foundation
@testable import MarkdownUI
import XCTest

final class BlockNodeRewriteTests: XCTestCase {
    private enum RewriteFailure: Error, Equatable {
        case expectedLeaf
    }

    func testBlockRewriteTraversesContainersPostorderAndPreservesMetadata() {
        let input: [BlockNode] = [
            .blockquote(
                children: [
                    .bulletedList(
                        isTight: false,
                        items: [
                            .init(children: [.paragraph(content: [.text("bullet")])])
                        ]
                    )
                ]
            ),
            .numberedList(
                isTight: true,
                start: 5,
                items: [
                    .init(children: [.paragraph(content: [.text("number")])])
                ]
            ),
            .taskList(
                isTight: true,
                items: [
                    .init(isCompleted: true, children: [.paragraph(content: [.text("task")])])
                ]
            ),
            .table(
                columnAlignments: [.left],
                rows: [.init(cells: [.init(content: [.text("cell")])])]
            )
        ]
        var visited: [String] = []

        let result = input.rewrite { block in
            visited.append(block.description)
            if case let .paragraph(content) = block {
                return [.heading(level: 2, content: content)]
            }
            return [block]
        }

        XCTAssertEqual(
            result,
            [
                .blockquote(
                    children: [
                        .bulletedList(
                            isTight: false,
                            items: [
                                .init(children: [.heading(level: 2, content: [.text("bullet")])])
                            ]
                        )
                    ]
                ),
                .numberedList(
                    isTight: true,
                    start: 5,
                    items: [
                        .init(children: [.heading(level: 2, content: [.text("number")])])
                    ]
                ),
                .taskList(
                    isTight: true,
                    items: [
                        .init(isCompleted: true, children: [.heading(level: 2, content: [.text("task")])])
                    ]
                ),
                .table(
                    columnAlignments: [.left],
                    rows: [.init(cells: [.init(content: [.text("cell")])])]
                )
            ]
        )
        XCTAssertEqual(
            visited,
            ["paragraph", "bulletedList", "blockquote", "paragraph", "numberedList", "paragraph", "taskList", "table"]
        )
    }

    func testBlockRewriteCanDeleteAndExpandNodes() {
        let input: [BlockNode] = [
            .paragraph(content: [.text("remove")]),
            .thematicBreak,
            .paragraph(content: [.text("keep")])
        ]

        let result = input.rewrite { block in
            switch block {
                case .paragraph(content: [.text("remove")]):
                    []
                case .thematicBreak:
                    [.thematicBreak, .paragraph(content: [.text("inserted")])]
                default:
                    [block]
            }
        }

        XCTAssertEqual(
            result,
            [
                .thematicBreak,
                .paragraph(content: [.text("inserted")]),
                .paragraph(content: [.text("keep")])
            ]
        )
    }

    func testInlineRewriteRecursesThroughTablesAndNestedInlineChildren() {
        let input: [BlockNode] = [
            .table(
                columnAlignments: [.none],
                rows: [
                    .init(
                        cells: [
                            .init(
                                content: [
                                    .strong(
                                        children: [
                                            .link(
                                                destination: "https://example.com",
                                                children: [.text("replace")]
                                            )
                                        ]
                                    )
                                ]
                            )
                        ]
                    )
                ]
            )
        ]

        let result = input.rewrite { inline in
            if case .text("replace") = inline {
                return [.text("rewritten")]
            }
            return [inline]
        }

        XCTAssertEqual(
            result,
            [
                .table(
                    columnAlignments: [.none],
                    rows: [
                        .init(
                            cells: [
                                .init(
                                    content: [
                                        .strong(
                                            children: [
                                                .link(
                                                    destination: "https://example.com",
                                                    children: [.text("rewritten")]
                                                )
                                            ]
                                        )
                                    ]
                                )
                            ]
                        )
                    ]
                )
            ]
        )
    }

    func testRewritePropagatesErrorsFromNestedLeaves() {
        let input: [BlockNode] = [
            .blockquote(
                children: [
                    .taskList(
                        isTight: true,
                        items: [.init(isCompleted: false, children: [.paragraph(content: [.text("fail")])])]
                    )
                ]
            )
        ]

        XCTAssertThrowsError(
            try input.rewrite { block in
                if case .paragraph(content: [.text("fail")]) = block {
                    throw RewriteFailure.expectedLeaf
                }
                return [block]
            }
        ) { error in
            XCTAssertEqual(error as? RewriteFailure, .expectedLeaf)
        }
    }
}

private extension BlockNode {
    var description: String {
        switch self {
            case .blockquote: "blockquote"
            case .bulletedList: "bulletedList"
            case .numberedList: "numberedList"
            case .taskList: "taskList"
            case .codeBlock: "codeBlock"
            case .htmlBlock: "htmlBlock"
            case .paragraph: "paragraph"
            case .heading: "heading"
            case .table: "table"
            case .thematicBreak: "thematicBreak"
        }
    }
}
