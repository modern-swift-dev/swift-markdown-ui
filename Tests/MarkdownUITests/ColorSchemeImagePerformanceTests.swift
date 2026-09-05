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
}
