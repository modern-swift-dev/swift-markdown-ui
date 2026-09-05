@testable import MarkdownUI
import SwiftUI
import XCTest

final class ColorSchemeImagePerformanceTests: XCTestCase {
    func testImageFreeContentReusesBlockStorage() {
        let content = MarkdownContent(String(repeating: "Paragraph with **style**.\n\n", count: 1000))
        XCTAssertTrue(content.colorSchemeImageBlockIndices.isEmpty)
        let filtered = content.blocks(matching: .dark)
        content.blocks.withUnsafeBufferPointer { original in
            filtered.withUnsafeBufferPointer { result in
                XCTAssertEqual(original.baseAddress, result.baseAddress)
            }
        }
    }

    func testOnlyConditionalImageBranchesAreSelectedIncludingNestedContainers() {
        let image = InlineNode.image(source: "image.png#GH-DARK-MODE-ONLY", children: [.text("dark")])
        let branches: [BlockNode] = [
            .paragraph(content: [.image(source: "plain.png#section", children: [])]),
            .blockquote(children: [.numberedList(isTight: true, start: 3, items: [
                .init(children: [.paragraph(content: [.strong(children: [image])])], isCompleted: true)
            ])]),
            .table(columnAlignments: [.left], rows: [.init(cells: [.init(content: [image])])]),
            .taskList(isTight: false, items: [.init(isCompleted: false, children: [.heading(level: 2, content: [image])])])
        ]
        let content = MarkdownContent(blocks: branches)
        XCTAssertEqual(content.colorSchemeImageBlockIndices, [1, 2, 3])
        XCTAssertEqual(content.blocks(matching: .light), branches.filterImagesMatching(colorScheme: .light))
        XCTAssertEqual(content.blocks(matching: .dark), branches)
        XCTAssertEqual(content.blocks, branches)
    }

    func testDSLAndParsedContentHaveEquivalentFilteringMetadata() {
        let parsed = MarkdownContent("![dark](image.png#gh-dark-mode-only)")
        let constructed = MarkdownContent(block: .paragraph(content: [
            .image(source: "image.png#gh-dark-mode-only", children: [.text("dark")])
        ]))
        XCTAssertEqual(parsed, constructed)
        XCTAssertEqual(parsed.blocks(matching: .light), [.paragraph(content: [])])
    }

    func testMatchingConditionalImagesReuseTopLevelStorage() {
        let content = MarkdownContent(blocks: [
            .blockquote(children: [
                .paragraph(content: [.image(source: "dark.png#gh-dark-mode-only", children: [.text("dark")])])
            ])
        ])
        let filtered = content.blocks(matching: .dark)
        assertSharedStorage(content.blocks, filtered)
        assertSharedStorage(content.blocks, content.blocks.filterImagesMatching(colorScheme: .dark))
    }

    func testChangedBranchPreservesUnchangedNestedSiblingStorage() throws {
        let unchangedInlines: [InlineNode] = [.strong(children: [.text("unchanged"), .code("code")])]
        let unchangedChildren: [BlockNode] = [.paragraph(content: unchangedInlines)]
        let content = MarkdownContent(blocks: [.blockquote(children: [
            .paragraph(content: [.image(source: "dark.png#gh-dark-mode-only", children: [])]),
            .blockquote(children: unchangedChildren)
        ])])
        let filtered = content.blocks(matching: .light)
        guard case let .blockquote(children) = try XCTUnwrap(filtered.first),
              case let .blockquote(retainedChildren) = children[1],
              case let .paragraph(retainedInlines) = retainedChildren[0] else {
            return XCTFail("Expected the nested sibling to remain unchanged")
        }
        XCTAssertEqual(children[0], .paragraph(content: []))
        assertSharedStorage(unchangedChildren, retainedChildren)
        assertSharedStorage(unchangedInlines, retainedInlines)
    }

    func testSpecializedFilteringMatchesLegacyRewriteAcrossNodeTypes() {
        let dark = InlineNode.image(source: "dark.png#GH-DARK-MODE-ONLY", children: [.text("dark")])
        let light = InlineNode.image(source: "light.png#gh-light-mode-only", children: [.text("light")])
        let mixed: [InlineNode] = [
            .text("text"), .softBreak, .lineBreak, .code("code"), .html("<span>html</span>"),
            .emphasis(children: [dark, .text("kept")]),
            .strong(children: [.strikethrough(children: [light])]),
            .link(destination: "page#gh-dark-mode-only", children: [light, dark]),
            .image(source: "plain.png", children: [dark, .strong(children: [light])]),
            .image(source: "plain.png#section", children: []),
            .image(source: "plain.png#", children: []),
            .image(source: "https://[invalid/#gh-light-mode-only", children: [.text("invalid URL")]),
            .image(source: "plain.png#gh-light-mode-only-extra", children: []),
            .image(source: "removed.png#gh-dark-mode-only", children: [light])
        ]
        let nodes: [BlockNode] = [
            .paragraph(content: mixed),
            .heading(level: 3, content: mixed),
            .blockquote(children: [.paragraph(content: mixed)]),
            .bulletedList(isTight: false, items: [.init(children: [.paragraph(content: mixed)], isCompleted: true)]),
            .numberedList(isTight: true, start: 7, items: [.init(children: [.paragraph(content: mixed)], isCompleted: false)]),
            .taskList(isTight: false, items: [.init(isCompleted: true, children: [.heading(level: 2, content: mixed)])]),
            .table(columnAlignments: [.left, .right], rows: [
                .init(cells: [.init(content: mixed), .init(content: [.text("unchanged")])]),
                .init(cells: [.init(content: [dark]), .init(content: [light])])
            ]),
            .codeBlock(fenceInfo: "swift", content: "![image](dark.png#gh-dark-mode-only)"),
            .htmlBlock(content: "<img src='dark.png#gh-dark-mode-only'>"),
            .thematicBreak
        ]
        for scheme in [ColorScheme.light, .dark] {
            let expected = nodes.rewrite { (inline: InlineNode) -> [InlineNode] in
                guard case let .image(source, _) = inline,
                      let fragment = URL(string: source)?.fragment?.lowercased() else {
                    return [inline]
                }
                if fragment == (scheme == .light ? "gh-dark-mode-only" : "gh-light-mode-only") {
                    return []
                }
                return [inline]
            }
            XCTAssertEqual(nodes.filterImagesMatching(colorScheme: scheme), expected)
            XCTAssertEqual(MarkdownContent(blocks: nodes).blocks(matching: scheme), expected)
            XCTAssertEqual(nodes.dropFirst().filterImagesMatching(colorScheme: scheme), Array(expected.dropFirst()))
        }
    }

    private func assertSharedStorage<Element>(
        _ original: [Element], _ result: [Element],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        original.withUnsafeBufferPointer { originalBuffer in
            result.withUnsafeBufferPointer { resultBuffer in
                XCTAssertEqual(originalBuffer.baseAddress, resultBuffer.baseAddress, file: file, line: line)
            }
        }
    }

}
