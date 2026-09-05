#if canImport(SwiftUI) && (os(macOS) || os(iOS))
@testable import MarkdownUIEditor
import XCTest

@MainActor final class MarkdownEditorSourceCacheTests: XCTestCase {
    func testRepeatedSourceReadsReuseParseAndChangesReplaceIt() {
        var parsedSources: [String] = []
        let cache = MarkdownEditorSourceCache { source in
            parsedSources.append(source)
            return MarkdownDocument(markdown: source)
        }

        for _ in 0 ..< 10 {
            XCTAssertEqual(cache.document(for: "**first**").markdown, "**first**\n")
        }
        XCTAssertEqual(parsedSources, ["**first**"])
        XCTAssertEqual(cache.document(for: "second").markdown, "second\n")
        XCTAssertEqual(cache.document(for: "**first**").markdown, "**first**\n")
        XCTAssertEqual(parsedSources, ["**first**", "second", "**first**"])
    }

    func testSwitchingToStructuredContentClearsPreviousParse() {
        var parses = 0
        let cache = MarkdownEditorSourceCache { source in
            parses += 1
            return MarkdownDocument(markdown: source)
        }
        _ = cache.document(for: "source")
        cache.clear()
        _ = cache.document(for: "source")
        XCTAssertEqual(parses, 2)
    }

    func testIndependentEditorsHaveIndependentCaches() {
        var parses = 0
        let parse: (String) -> MarkdownDocument = { source in
            parses += 1
            return MarkdownDocument(markdown: source)
        }
        let first = MarkdownEditorSourceCache(parse: parse)
        let second = MarkdownEditorSourceCache(parse: parse)
        _ = first.document(for: "same")
        _ = second.document(for: "same")
        _ = first.document(for: "same")
        XCTAssertEqual(parses, 2)
    }
}
#endif
