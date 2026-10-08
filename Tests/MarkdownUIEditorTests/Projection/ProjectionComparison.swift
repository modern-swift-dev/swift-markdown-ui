import Foundation
@testable import MarkdownUIEditor
import XCTest

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Compares projected text and mappings without build-local identities.
///
/// Node identifiers are random per build, and every build creates its own
/// text lists and attachments. Values compare by content, while text lists
/// compare by marker format and by which runs share them.
@MainActor enum ProjectionComparison {
    /// A document exercising every projected block and inline construct.
    static let richMarkdown = """
    # Heading *one* with `code`

    ## Heading **two** [link](https://example.com "Title")

    ###### Six ~~struck~~

    Plain *emphasis* **strong** ***both*** ~~strike~~ `code` <span>html</span> \\*escaped\\* e\u{301} 👩‍👩‍👧‍👦
    soft break and hard break\\
    [**bold link**](<https://example.com/a b>) ![alt *text*](image.png "Image")

    > Quote with **bold**
    >
    > > Nested quote
    >
    > - quoted item
    > - second quoted item

    1. one
    2. two **bold**

       continuation paragraph
    3. three

    7. start at seven
    8. eight

    - [ ] open task *em*
    - [x] done task `code`
      - nested bullet
        1. nested ordered

    ```swift
    let value = "```"
    ```

    <div>
    block html
    </div>

    | Header | **Bold** | Right |
    | :--- | :---: | ---: |
    | cell | `code` | [link](x) |
    | two |  | ~~gone~~ |

    ---

    > | Quoted | Table |
    > | --- | --- |
    > | a | b |

    Final paragraph.
    """

    static var richDocument: MarkdownDocument {
        MarkdownDocument(markdown: richMarkdown)
    }

    /// Asserts that native text and its index match a fresh projection.
    static func assertEquivalent(
        _ text: NSAttributedString,
        _ index: ProjectionIndex,
        to expected: DocumentProjection,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(text.string, expected.string, "string \(message())", file: file, line: line)
        XCTAssertEqual(
            describe(index),
            describe(expected.index),
            "index \(message())",
            file: file,
            line: line
        )
        XCTAssertEqual(index.projectionUTF16Length, text.length, "index length \(message())", file: file, line: line)
        assertConsistentIdentities(text, index, message(), file: file, line: line)
        let actualRuns = runs(of: text)
        let expectedRuns = runs(of: expected.attributedString)
        XCTAssertEqual(actualRuns.count, expectedRuns.count, "run count \(message())", file: file, line: line)
        for (actual, expected) in zip(actualRuns, expectedRuns) {
            XCTAssertEqual(actual.range, expected.range, "run range \(message())", file: file, line: line)
            XCTAssertTrue(
                actual.attributes.isEqual(expected.attributes),
                "attributes at \(actual.range) \(message())\nactual: \(actual.attributes)\nexpected: \(expected.attributes)",
                file: file,
                line: line
            )
        }
    }

    /// Units without their random identifiers.
    static func describe(_ index: ProjectionIndex) -> [String] {
        index.units.map { unit in
            "\(unit.path) \(unit.kind) \(unit.projectionRange) \(unit.sourceRange) \(unit.segments)"
        }
    }

    /// Every unit's identifier must match the identifier stored on its text.
    private static func assertConsistentIdentities(
        _ text: NSAttributedString,
        _ index: ProjectionIndex,
        _ message: String,
        file: StaticString,
        line: UInt
    ) {
        for unit in index.units where unit.projectionRange.length > 0 && unit.projectionRange.upperBound <= text.length {
            let id = text.attribute(.markdownEditorNodeID, at: unit.projectionRange.location, effectiveRange: nil) as? String
            XCTAssertEqual(id, unit.id.description, "identity of \(unit.path) \(message)", file: file, line: line)
        }
    }

    /// Maximal runs of normalized attributes.
    static func runs(of text: NSAttributedString) -> [(range: NSRange, attributes: NSDictionary)] {
        var textLists: [ObjectIdentifier] = []
        var result: [(range: NSRange, attributes: NSDictionary)] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let normalized = NSMutableDictionary()
            for (key, value) in attributes {
                normalized[key] = normalizedValue(value, for: key, textLists: &textLists)
            }
            if let last = result.last, last.attributes.isEqual(normalized),
               NSMaxRange(last.range) == range.location {
                result[result.count - 1].range.length += range.length
            } else {
                result.append((range, normalized))
            }
        }
        return result
    }

    private static func normalizedValue(
        _ value: Any,
        for key: NSAttributedString.Key,
        textLists: inout [ObjectIdentifier]
    ) -> Any {
        if key == .markdownEditorNodeID {
            return "<id>"
        }
        if let style = value as? NSParagraphStyle, let copy = style.mutableCopy() as? NSMutableParagraphStyle {
            let lists = style.textLists.map { list -> String in
                let identity = ObjectIdentifier(list)
                let ordinal = textLists.firstIndex(of: identity) ?? textLists.count
                if ordinal == textLists.count {
                    textLists.append(identity)
                }
                return "list#\(ordinal) \(list.markerFormat.rawValue) \(list.startingItemNumber)"
            }
            copy.textLists = []
            return "\(copy) \(lists)"
        }
        if let attachment = value as? MarkdownTableAttachment {
            return "table \(attachment.table)"
        }
        if let attachment = value as? MarkdownImageAttachment {
            return "image \(attachment.metadata) \(attachment.altContent)"
        }
        return value
    }
}
