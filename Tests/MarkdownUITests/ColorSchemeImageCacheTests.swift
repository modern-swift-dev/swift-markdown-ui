@testable import MarkdownUI
import SwiftUI
import XCTest

@MainActor final class ColorSchemeImageCacheTests: XCTestCase {
    func testRepeatedEvaluationsReuseFilteringAcrossUnrelatedViewUpdates() {
        var calls = 0
        let cache = ColorSchemeImageCache { content, scheme, indices in
            calls += 1
            return content.blocks(matching: scheme, conditionalImageBlockIndices: indices)
        }
        let content = MarkdownContent("Text ![dark](dark.png#gh-dark-mode-only) ![light](light.png#gh-light-mode-only)")
        let first = cache.blocks(for: content, matching: .light)
        for _ in 0 ..< 25 {
            // Image loading and theme changes can reevaluate a view without
            // changing either input to conditional-image filtering.
            assertSharedStorage(first, cache.blocks(for: content, matching: .light))
        }
        let equalDeferredContent = MarkdownContent(configurationBlocks: content.blocks)
        assertSharedStorage(first, cache.blocks(for: equalDeferredContent, matching: .light))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(first, content.blocks(matching: .light))
    }

    func testColorAndContentChangesReplaceTheOnlyCachedVariant() {
        var calls = 0
        let cache = ColorSchemeImageCache { content, scheme, indices in
            calls += 1
            return content.blocks(matching: scheme, conditionalImageBlockIndices: indices)
        }
        let first = MarkdownContent("First ![dark](dark.png#gh-dark-mode-only) ![light](light.png#gh-light-mode-only)")
        let second = MarkdownContent("Second ![dark](dark.png#gh-dark-mode-only)")
        for (content, scheme) in [(first, ColorScheme.light), (first, .dark), (first, .light), (second, .light), (first, .light)] {
            XCTAssertEqual(cache.blocks(for: content, matching: scheme), content.blocks(matching: scheme))
        }
        XCTAssertEqual(calls, 5, "Returning to an old document or scheme must filter again rather than retain multiple variants")
    }

    func testImageFreeContentBypassesFilteringAndEvictsConditionalResult() {
        var calls = 0
        let cache = ColorSchemeImageCache { content, scheme, indices in
            calls += 1
            return content.blocks(matching: scheme, conditionalImageBlockIndices: indices)
        }
        let conditional = MarkdownContent("![dark](dark.png#gh-dark-mode-only)")
        let plain = MarkdownContent("Plain **text** and ![ordinary](image.png#section)")
        _ = cache.blocks(for: conditional, matching: .light)
        for scheme in [ColorScheme.light, .dark] {
            assertSharedStorage(plain.blocks, cache.blocks(for: plain, matching: scheme))
        }
        let empty = MarkdownContent(blocks: [])
        XCTAssertTrue(cache.blocks(for: empty, matching: .light).isEmpty)
        XCTAssertEqual(calls, 1)
        _ = cache.blocks(for: conditional, matching: .light)
        XCTAssertEqual(calls, 2)
    }

    func testDeferredContentSuppliesResolvedIndicesToFilter() {
        var calls = 0
        let cache = ColorSchemeImageCache { content, scheme, indices in
            calls += 1
            XCTAssertEqual(indices, [1])
            return content.blocks(matching: scheme, conditionalImageBlockIndices: indices)
        }
        let content = MarkdownContent(configurationBlocks: [
            .paragraph(content: [.text("plain")]),
            .paragraph(content: [.image(source: "dark.png#gh-dark-mode-only", children: [])])
        ])
        XCTAssertEqual(cache.blocks(for: content, matching: .light), [
            .paragraph(content: [.text("plain")]), .paragraph(content: [])
        ])
        _ = cache.blocks(for: content, matching: .light)
        XCTAssertEqual(calls, 1)
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
