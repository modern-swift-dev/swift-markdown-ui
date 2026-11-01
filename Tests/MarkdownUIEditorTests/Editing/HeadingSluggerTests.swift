import Foundation
@testable import MarkdownUIEditor
import XCTest

@MainActor final class HeadingSluggerTests: XCTestCase {
    func testHeadingIdentifiersMatchTheSharedGitHubCorpus() throws {
        var slugger = HeadingSlugger()
        for entry in try HeadingIdentifierCorpus.load() {
            XCTAssertEqual(slugger.identifier(for: entry.input), entry.expected, entry.name)
        }
    }

    func testHeadingIdentifiersMatchGitHubForHeadingsWithHTMLAndImages() throws {
        for entry in try HeadingAnchorFixture.load() {
            var slugger = HeadingSlugger()
            let identifiers = MarkdownDocument(markdown: entry.markdown).blocks.compactMap { block -> String? in
                guard case let .heading(_, content) = block else {
                    return nil
                }
                return slugger.identifier(for: HeadingSlugger.plainText(content))
            }
            XCTAssertEqual(identifiers, entry.expected, entry.name)
        }
    }

    func testFragmentLinksFindDuplicateAndNestedHeadingsInDocumentOrder() {
        let session = MarkdownEditingSession(document: MarkdownDocument(markdown: """
        # Hello, World!

        > ## Hello, World!

        - ### Hello, *World*!

        Body
        """))
        let text = session.projection.attributedString.string as NSString

        func heading(_ destination: String) -> String? {
            session.headingProjectionRange(forLinkDestination: destination).map { text.substring(with: $0) }
        }

        XCTAssertEqual(heading("#hello-world"), "Hello, World!\n")
        XCTAssertEqual(heading("#hello-world-1"), "Hello, World!\n")
        XCTAssertNotEqual(
            session.headingProjectionRange(forLinkDestination: "#hello-world"),
            session.headingProjectionRange(forLinkDestination: "#hello-world-1")
        )
        XCTAssertEqual(heading("#hello-world-2"), "Hello, World!\n")
        XCTAssertNil(heading("#hello-world-3"))
        XCTAssertNil(heading("#body"))
        XCTAssertNil(heading("hello-world"))
        XCTAssertNil(heading("https://example.com/#hello-world"))
    }

    func testFragmentLinksMatchPercentEncodedIdentifiers() {
        let session = MarkdownEditingSession(document: MarkdownDocument(markdown: "# Привет мир"))

        XCTAssertNotNil(session.headingProjectionRange(forLinkDestination: "#привет-мир"))
        XCTAssertNotNil(session.headingProjectionRange(forLinkDestination: "#%D0%BF%D1%80%D0%B8%D0%B2%D0%B5%D1%82-%D0%BC%D0%B8%D1%80"))
    }
}

/// Reads the corpus shared with the renderer tests, so both modules stay on one algorithm.
///
/// The cases are github-slugger's fixtures, which were generated from GitHub's rendered
/// heading anchors (https://github.com/Flet/github-slugger, `test/fixtures.json`). The
/// "Unassigned" fixture is left out: Swift's newer Unicode tables assign some of its
/// code points, which Unicode 13 left unassigned.
enum HeadingIdentifierCorpus {
    struct Entry: Decodable {
        let name: String
        let input: String
        let expected: String
    }

    static func load() throws -> [Entry] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HeadingIdentifierCorpus.json")
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
    }
}

/// Reads the heading documents shared with the renderer tests, with the anchors GitHub gives their headings.
enum HeadingAnchorFixture {
    struct Entry: Decodable {
        let name: String
        let markdown: String
        let expected: [String]
    }

    static func load() throws -> [Entry] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HeadingAnchorFixture.json")
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
    }
}
