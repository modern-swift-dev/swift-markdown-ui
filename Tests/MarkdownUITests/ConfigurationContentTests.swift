@testable import MarkdownUI
import SwiftUI
import XCTest

final class ConfigurationContentTests: XCTestCase {
    func testDeferredContentRetainsEqualityAndRenderingRepresentations() {
        let original = MarkdownContent("> - [x] **done**\n> - [ ] ![dark](image.png#gh-dark-mode-only)")
        let deferred = MarkdownContent(configurationBlocks: original.blocks)

        guard case .deferred = deferred.colorSchemeImageIndex else {
            return XCTFail("Style content must not scan its descendants during construction")
        }
        XCTAssertEqual(deferred, original)
        XCTAssertEqual(deferred.renderMarkdown(), original.renderMarkdown())
        XCTAssertEqual(deferred.renderPlainText(), original.renderPlainText())
        XCTAssertEqual(deferred.renderHTML(), original.renderHTML())
        XCTAssertEqual(deferred.childContent, original.childContent)
        for scheme in [ColorScheme.light, .dark] {
            XCTAssertEqual(deferred.blocks(matching: scheme), original.blocks(matching: scheme))
        }
    }

    func testDeferredImageFreeContentReusesBlockStorage() {
        var block = BlockNode.paragraph(content: [.text("leaf")])
        for _ in 0 ..< 100 {
            block = .blockquote(children: [block])
        }
        let content = MarkdownContent(configurationBlock: block)
        let filtered = content.blocks(matching: .dark)
        content.blocks.withUnsafeBufferPointer { original in
            filtered.withUnsafeBufferPointer { result in
                XCTAssertEqual(original.baseAddress, result.baseAddress)
            }
        }
    }
}
