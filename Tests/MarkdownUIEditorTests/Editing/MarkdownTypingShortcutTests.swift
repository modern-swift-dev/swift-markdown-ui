@testable import MarkdownUIEditor
import XCTest

final class MarkdownTypingShortcutTests: XCTestCase {
    func testMarkersMatchOnlyWithTheirTriggerKey() {
        let matches: [(String, String, MarkdownTypingShortcut)] = [
            ("#", " ", .heading(.one)),
            ("###", " ", .heading(.three)),
            ("######", " ", .heading(.six)),
            ("-", " ", .bulletList),
            ("*", " ", .bulletList),
            ("+", " ", .bulletList),
            ("1.", " ", .orderedList(start: 1)),
            ("42)", " ", .orderedList(start: 42)),
            ("[ ]", " ", .task(.unchecked)),
            ("[x]", " ", .task(.checked)),
            (">", " ", .blockquote),
            ("```", "\n", .codeBlock(info: nil)),
            ("```swift", "\n", .codeBlock(info: "swift")),
            ("``` swift ", "\n", .codeBlock(info: "swift"))
        ]
        for (marker, typed, expected) in matches {
            XCTAssertEqual(MarkdownTypingShortcut(marker: marker, typed: typed), expected, marker)
        }
        let misses: [(String, String)] = [
            ("#######", " "), ("#a", " "), ("--", " "), ("1", " "), ("a.", " "), ("1234567890.", " "),
            ("[]", " "), ("[y]", " "), (">>", " "), ("#", "\n"), ("-", "a"),
            ("```", " "), ("``", "\n"), ("```a`b", "\n"), ("---", " ")
        ]
        for (marker, typed) in misses {
            XCTAssertNil(MarkdownTypingShortcut(marker: marker, typed: typed), "\(marker) + \(typed.debugDescription)")
        }
    }
}
