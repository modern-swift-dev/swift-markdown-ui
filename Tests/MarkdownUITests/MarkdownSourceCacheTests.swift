import Foundation
@testable import MarkdownUI
import os
import XCTest

final class MarkdownSourceCacheTests: XCTestCase {
    func testRepeatedSourcesParseOnce() {
        let parses = OSAllocatedUnfairLock(initialState: [String]())
        let cache = MarkdownSourceCache { source in
            parses.withLock { $0.append(source) }
            return MarkdownContent(source)
        }
        for _ in 0 ..< 3 {
            XCTAssertEqual(cache.content(for: "**first**"), MarkdownContent("**first**"))
            XCTAssertEqual(cache.content(for: "second"), MarkdownContent("second"))
        }
        XCTAssertEqual(parses.withLock { $0 }, ["**first**", "second"])
    }

    func testEvictsLeastRecentlyUsedSourceBeyondEntryCount() {
        let parses = OSAllocatedUnfairLock(initialState: 0)
        let cache = MarkdownSourceCache(maximumEntryCount: 2) { source in
            parses.withLock { $0 += 1 }
            return MarkdownContent(source)
        }
        _ = cache.content(for: "a")
        _ = cache.content(for: "b")
        _ = cache.content(for: "a")
        _ = cache.content(for: "c")
        XCTAssertNotNil(cache.cachedContent(for: "a"))
        XCTAssertNil(cache.cachedContent(for: "b"))
        XCTAssertNotNil(cache.cachedContent(for: "c"))
        XCTAssertEqual(parses.withLock { $0 }, 3)
    }

    func testEvictsBeyondByteCountAndBypassesOversizedSources() {
        let parses = OSAllocatedUnfairLock(initialState: 0)
        let cache = MarkdownSourceCache(maximumByteCount: 8) { source in
            parses.withLock { $0 += 1 }
            return MarkdownContent(source)
        }
        _ = cache.content(for: "1234")
        _ = cache.content(for: "5678")
        _ = cache.content(for: "9")
        XCTAssertNil(cache.cachedContent(for: "1234"))
        XCTAssertNotNil(cache.cachedContent(for: "5678"))
        XCTAssertNotNil(cache.cachedContent(for: "9"))

        _ = cache.content(for: "too large!")
        _ = cache.content(for: "too large!")
        XCTAssertNil(cache.cachedContent(for: "too large!"))
        XCTAssertEqual(parses.withLock { $0 }, 5)
    }

    func testConcurrentAccessReturnsParsedContent() {
        let cache = MarkdownSourceCache(maximumEntryCount: 4)
        let sources = (0 ..< 8).map { "Paragraph **\($0)**" }
        DispatchQueue.concurrentPerform(iterations: 200) { iteration in
            let source = sources[iteration % sources.count]
            XCTAssertEqual(cache.content(for: source), MarkdownContent(source))
        }
    }

    func testBuilderStringsAreParsedOnceAcrossEvaluations() {
        let source = "Builder **\(UUID().uuidString)** with ![dark](image.png#gh-dark-mode-only)"
        @MarkdownContentBuilder func build() -> MarkdownContent {
            source
        }

        XCTAssertNil(MarkdownSourceCache.shared.cachedContent(for: source))
        let first = build()
        let cached = MarkdownSourceCache.shared.cachedContent(for: source)
        XCTAssertNotNil(cached)
        XCTAssertEqual(first, MarkdownContent(source))
        XCTAssertEqual(build(), first)
        XCTAssertEqual(MarkdownSourceCache.shared.cachedContent(for: source), cached)
        XCTAssertEqual(first.colorSchemeImageBlockIndices, [0])
    }

    func testNestedBuilderElementsDeferImageScanUntilTheContentIsComplete() throws {
        let lightImage = try XCTUnwrap(URL(string: "image.png#gh-light-mode-only"))
        @MarkdownContentBuilder func build() -> MarkdownContent {
            "Intro"
            Blockquote {
                Blockquote {
                    Paragraph {
                        InlineImage(source: lightImage)
                    }
                }
            }
            "![dark](image.png#gh-dark-mode-only)"
        }

        let intermediate = build()
        guard case .deferred = intermediate.colorSchemeImageIndex else {
            return XCTFail("Builder results that contain elements must not scan their descendants")
        }
        let content = MarkdownContent { build() }
        guard case let .known(indices) = content.colorSchemeImageIndex else {
            return XCTFail("Complete builder content must scan once for conditional images")
        }
        XCTAssertEqual(indices, [1, 2])
        XCTAssertEqual(content, intermediate)
        XCTAssertEqual(intermediate.colorSchemeImageBlockIndices, indices)
    }

    func testStringOnlyBuilderReusesCachedImageIndices() {
        @MarkdownContentBuilder func build() -> MarkdownContent {
            "First"
            "![dark](image.png#gh-dark-mode-only)\n\nSecond"
        }

        guard case let .known(indices) = build().colorSchemeImageIndex else {
            return XCTFail("Cached strings already know their conditional-image indices")
        }
        XCTAssertEqual(indices, [1])
    }
}
