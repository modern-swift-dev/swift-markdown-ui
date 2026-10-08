#if canImport(SwiftUI) && (os(macOS) || os(iOS))
    @testable import MarkdownUIEditor
    import SwiftUI
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

        func testPublishedDocumentReadsBackWithoutParsing() {
            var parses = 0
            var serializations = 0
            let cache = MarkdownEditorSourceCache(
                parse: { source in
                    parses += 1
                    return MarkdownDocument(markdown: source)
                },
                serialize: { document in
                    serializations += 1
                    return document.markdown
                }
            )
            var markdown = "text"
            let binding = cache.documentBinding(for: Binding(get: { markdown }, set: { markdown = $0 }))
            XCTAssertEqual(binding.wrappedValue, MarkdownDocument(markdown: "text"))
            XCTAssertEqual(parses, 1)

            // Markdown drops the empty paragraph, but the read-back is the published draft.
            let draft = MarkdownDocument(blocks: [.paragraph([.text("textX")]), .paragraph([])])
            binding.wrappedValue = draft
            XCTAssertEqual(markdown, "textX\n")
            XCTAssertEqual(binding.wrappedValue, draft)
            XCTAssertEqual(binding.wrappedValue, draft)
            XCTAssertEqual(parses, 1)
            XCTAssertEqual(serializations, 1)

            markdown = "external"
            XCTAssertEqual(binding.wrappedValue, MarkdownDocument(markdown: "external"))
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
