import Foundation
@testable import MarkdownUI
import XCTest

final class IncrementalMarkdownParserTests: XCTestCase {
    private static let mixedDocument = """
    # Résumé

    Intro paragraph with *emphasis* and a [link](https://example.com).
    Second line of the same paragraph.

    > - [x] completed
    > - [ ] pending

    | Name | Value |
    | :--- | ---: |
    | *café* | ~~42~~ |

    <span>inline HTML</span>

    Setext heading
    ==============

    - item one
    - item two

      continued item paragraph

    1. first
    2. second

        indented code

    Paragraph after code.

    ***

    ```swift
    let value = 42

    print(value)
    ```

    ~~~
    tilde fence
    ~~~

    Text before table
    | a | b |
    | - | - |
    | 1 | 2 |

    ![dark](https://example.com/dark.png#gh-dark-mode-only)
    ![light](https://example.com/light.png#gh-light-mode-only)

    Final paragraph 👩‍👩‍👧 with emoji.
    """

    private static let indentationDocument = """
    Paragraph

    \tcode with tab

    Paragraph
     - list with space
    \t- nested

        code

        more code after blank

    end

    > quote
    lazy continuation

    > quote two

    para

    - a
    b lazy

    text
    """

    private static let headingDocument = """
    # One

    ## Two
    Para
    ---

    Para 2

    ---
    Para 3
    ===

    ####### not heading

    * * *

    Closing paragraph
    """

    private static let htmlDocument = """
    para

    <script>
    var x = 1;

    var y = 2;
    </script>

    para

    <pre>

    </pre>

    <!-- comment

    still comment -->

    <div>
    block html
    </div>

    <?php

    ?>

    <![CDATA[

    ]]>

    <custom-tag>

    para
    """

    private static let referenceDocument = """
    See [the guide][guide] and [other].

    Middle paragraph.

    [guide]: https://example.com/guide

    Last [other] paragraph.

    [other]: /other
    """

    private static var fixtures: [String] {
        let documents = [
            mixedDocument,
            indentationDocument,
            headingDocument,
            htmlDocument,
            referenceDocument
        ]
        return documents
            + documents.map { $0.replacingOccurrences(of: "\n", with: "\r\n") }
            + documents.map { $0.replacingOccurrences(of: "\n", with: "\r") }
    }

    func testStreamingScalarByScalarMatchesFullParse() {
        for fixture in Self.fixtures {
            self.assertStreamingMatchesFullParse(fixture, chunkSizes: [1])
        }
    }

    func testStreamingVariableChunksMatchesFullParse() {
        for fixture in Self.fixtures {
            self.assertStreamingMatchesFullParse(fixture, chunkSizes: [3, 1, 7, 2, 11, 5])
        }
    }

    func testStreamingAndEditingRandomDocumentsMatchesFullParse() throws {
        let lines = [
            "", "", "", "Paragraph text", "more *emphasis", "closing* text", "- item", "* other item", "1. first",
            "2) second", "  indented continuation", "    indented code", "\tTabbed", "```", "~~~", "> quote", ">",
            "# Heading", "Setext", "===", "---", "***", "* * *", "| a | b |", "| - | - |", "| 1 | 2 |", "<div>",
            "</div>", "<!--", "-->", "<script>", "</script>", "<pre>", "</pre>", "- [ ] task", "- [x] done",
            "![dark](a.png#gh-dark-mode-only)", "[x] not a definition", "<span>inline</span>", "\\", "<custom-tag>"
        ]
        var generator = SplitMix64(seed: 42)
        for _ in 0 ..< 150 {
            let separator = ["\n", "\r\n", "\r"][Int.random(in: 0 ..< 3, using: &generator)]
            var document = (0 ..< Int.random(in: 4 ... 30, using: &generator)).map { _ in
                lines[Int.random(in: lines.indices, using: &generator)]
            }
            let chunkSizes = (0 ..< 4).map { _ in Int.random(in: 1 ... 9, using: &generator) }
            var parser = IncrementalMarkdownParser()
            for prefix in Self.prefixes(of: document.joined(separator: separator), chunkSizes: chunkSizes) {
                Self.assertParse(&parser, matchesFullParseOf: prefix)
            }
            // Replace, insert, or remove whole lines anywhere in the document.
            for _ in 0 ..< 20 {
                let index = Int.random(in: 0 ..< document.count, using: &generator)
                switch Int.random(in: 0 ..< 3, using: &generator) {
                    case 0:
                        document[index] = try XCTUnwrap(lines.randomElement(using: &generator))
                    case 1:
                        document.insert(try XCTUnwrap(lines.randomElement(using: &generator)), at: index)
                    default:
                        if document.count > 1 {
                            document.remove(at: index)
                        }
                }
                Self.assertParse(&parser, matchesFullParseOf: document.joined(separator: separator))
            }
        }
    }

    func testStreamingReusesLeadingBlocks() {
        let markdown = (0 ..< 40).map { "Paragraph \($0) with some text." }.joined(separator: "\n\n")
        var parser = IncrementalMarkdownParser()
        var reused = 0
        for prefix in Self.prefixes(of: markdown, chunkSizes: [4]) {
            XCTAssertEqual(parser.parse(prefix), MarkdownContent(prefix))
            reused = max(reused, parser.reusedBlockCount)
        }
        XCTAssertEqual(parser.reusedBlockCount, 39)
        XCTAssertEqual(reused, 39)

        var mixedParser = IncrementalMarkdownParser()
        var mixedReuses = 0
        for prefix in Self.prefixes(of: Self.mixedDocument, chunkSizes: [1]) {
            _ = mixedParser.parse(prefix)
            mixedReuses += mixedParser.reusedBlockCount > 0 ? 1 : 0
        }
        XCTAssertGreaterThan(mixedReuses, 0)
    }

    func testEditsBeforeTheTailMatchFullParse() {
        let base = Self.mixedDocument
        let edits = [
            base,
            base.replacingOccurrences(of: "Intro paragraph", with: "Intro"),
            base.replacingOccurrences(of: "Paragraph after code.", with: "```\nunclosed fence"),
            base.replacingOccurrences(of: "***", with: "    ***"),
            base.replacingOccurrences(of: "Final paragraph", with: "  continued item"),
            base.replacingOccurrences(of: "\n\nFinal paragraph", with: "\nFinal paragraph"),
            base.replacingOccurrences(of: "Final paragraph", with: "\u{FEFF}Final paragraph"),
            base.replacingOccurrences(of: "Final paragraph", with: "[link]: /url\n\nFinal paragraph"),
            String(base.prefix(base.count / 2)),
            base + "\n\n[link]: /url",
            base,
            "",
            base,
            base + "\n\n- trailing list",
            base + "\n\n- trailing list\n  continued",
            base + "\r\nCR LF tail",
            base
        ]
        var parser = IncrementalMarkdownParser()
        for source in edits {
            Self.assertParse(&parser, matchesFullParseOf: source)
        }
    }

    func testCarriageReturnSplitByAChunkMatchesFullParse() {
        var parser = IncrementalMarkdownParser()
        for source in ["a\n\nb\r", "a\n\nb\r\nc", "a\r\rb\r\r", "a\r\rb\r\r\n", "a\r\rb\r\r\nc"] {
            Self.assertParse(&parser, matchesFullParseOf: source)
        }
    }

    func testReferenceDefinitionsForceFullParse() {
        var parser = IncrementalMarkdownParser()
        _ = parser.parse("Use [a].\n\nSecond paragraph.\n\nThird")
        XCTAssertEqual(parser.reusedBlockCount, 0)
        _ = parser.parse("Use [a].\n\nSecond paragraph.\n\nThird paragraph")
        XCTAssertEqual(parser.reusedBlockCount, 2)

        let source = "Use [a].\n\nSecond paragraph.\n\n[a]: /destination"
        Self.assertParse(&parser, matchesFullParseOf: source)
        XCTAssertEqual(parser.reusedBlockCount, 0)
        Self.assertParse(&parser, matchesFullParseOf: source + "\n\nMore")
        XCTAssertEqual(parser.reusedBlockCount, 0)
    }

    @MainActor func testCacheParsesIncrementallyAndMatchesFullParse() {
        let cache = MarkdownContentCache()
        for prefix in Self.prefixes(of: Self.mixedDocument, chunkSizes: [5]) {
            XCTAssertEqual(cache.content(for: prefix), MarkdownContent(prefix))
        }
        cache.clear()
        XCTAssertEqual(cache.content(for: Self.headingDocument), MarkdownContent(Self.headingDocument))
    }

    private func assertStreamingMatchesFullParse(
        _ markdown: String,
        chunkSizes: [Int],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var parser = IncrementalMarkdownParser()
        for prefix in Self.prefixes(of: markdown, chunkSizes: chunkSizes) {
            Self.assertParse(&parser, matchesFullParseOf: prefix, file: file, line: line)
        }
    }

    private static func assertParse(
        _ parser: inout IncrementalMarkdownParser,
        matchesFullParseOf source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let incremental = parser.parse(source)
        let full = MarkdownContent(source)
        XCTAssertEqual(incremental, full, "Source: \(source.debugDescription)", file: file, line: line)
        XCTAssertEqual(
            incremental.colorSchemeImageBlockIndices,
            full.colorSchemeImageBlockIndices,
            "Source: \(source.debugDescription)",
            file: file,
            line: line
        )
    }

    /// Splits by Unicode scalars so that chunks can separate a carriage return from its line feed.
    private static func prefixes(of markdown: String, chunkSizes: [Int]) -> [String] {
        let scalars = Array(markdown.unicodeScalars)
        var prefixes: [String] = []
        var end = 0
        var chunk = 0
        while end < scalars.count {
            end = min(end + chunkSizes[chunk % chunkSizes.count], scalars.count)
            chunk += 1
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[..<end])
            prefixes.append(String(view))
        }
        return prefixes
    }
}

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var value = self.state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
