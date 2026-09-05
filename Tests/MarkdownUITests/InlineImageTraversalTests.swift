@testable import MarkdownUI
import XCTest

final class InlineImageTraversalTests: XCTestCase {
    func testNestedAltTextAndImageDiscoveryPreserveOrderAndDeduplicateRequests() {
        let alt: [InlineNode] = [
            .text("A"), .emphasis(children: [.text(" cat"), .softBreak]),
            .code("code"), .lineBreak, .html("<tag>"),
            .link(destination: "ignored", children: [.strong(children: [.text("linked")])])
        ]
        let first = InlineNode.image(source: "photo.png", children: alt)
        let second = InlineNode.image(source: "photo.png", children: [.text("different label")])
        let inlines: [InlineNode] = [
            .strong(children: [first]),
            .link(destination: "target", children: [second]), first
        ]
        let expected = RawImageData(source: "photo.png", alt: "A cat code\n<tag>linked")
        XCTAssertEqual(alt.renderPlainText(), expected.alt)
        XCTAssertEqual(inlines.inlineImageData(), [expected, .init(source: "photo.png", alt: "different label"), expected])
        XCTAssertEqual(inlines.inlineImageDataSet(), Set(inlines.inlineImageData()))
    }

    func testCollectionRetainsPostorderWithoutIntermediateSubtreeArrays() {
        let nodes: [InlineNode] = [.emphasis(children: [.text("a"), .strong(children: [.text("b")])])]
        let result = nodes.collect { node -> [String] in
            switch node {
                case let .text(value): [value]
                case .strong: ["strong"]
                case .emphasis: ["emphasis"]
                default: []
            }
        }
        XCTAssertEqual(result, ["a", "b", "strong", "emphasis"])
    }
}
