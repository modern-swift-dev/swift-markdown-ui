import Foundation
@testable import MarkdownUI
import XCTest

final class MarkdownStressTests: XCTestCase {
    func testRepeatedParsingAndRenderingIsDeterministicForMixedGFMDocument() {
        let markdown = """
        # Résumé

        > - [x] completed
        > - [ ] pending with [link](https://example.com/a?x=1&y=2)

        | Name | Value |
        | :--- | ---: |
        | *café* | ~~42~~ |

        <span>inline HTML</span>
        """
        let baseline = MarkdownContent(markdown)
        let expectedMarkdown = baseline.renderMarkdown()
        let expectedPlainText = baseline.renderPlainText()
        let expectedHTML = baseline.renderHTML()

        for _ in 0 ..< 40 {
            let content = MarkdownContent(markdown)
            XCTAssertEqual(content, baseline)
            XCTAssertEqual(content.renderMarkdown(), expectedMarkdown)
            XCTAssertEqual(content.renderPlainText(), expectedPlainText)
            XCTAssertEqual(content.renderHTML(), expectedHTML)
            XCTAssertEqual(MarkdownContent(content.renderMarkdown()), content)
        }
    }

    func testNestedContainersRetainStructureThroughRepeatedRoundTrips() {
        let markdown = (0 ..< 24).map { depth in
            String(repeating: "> ", count: depth + 1) + "- level \(depth)"
        }
        .joined(separator: "\n")
        let baseline = MarkdownContent(markdown)
        let normalized = baseline.renderMarkdown()

        XCTAssertEqual(baseline.blocks.count, 1)
        for _ in 0 ..< 20 {
            XCTAssertEqual(MarkdownContent(markdown), baseline)
            XCTAssertEqual(MarkdownContent(normalized), baseline)
        }
    }

    func testLargeSingleParagraphKeepsUnicodeAndWhitespaceStable() {
        let line = "naïve café ☕\u{00A0}"
        let markdown = Array(repeating: line, count: 256).joined(separator: "\n")
        let baseline = MarkdownContent(markdown)

        for _ in 0 ..< 10 {
            let content = MarkdownContent(markdown)
            XCTAssertEqual(content, baseline)
            XCTAssertEqual(content.renderPlainText(), baseline.renderPlainText())
        }
    }
}
