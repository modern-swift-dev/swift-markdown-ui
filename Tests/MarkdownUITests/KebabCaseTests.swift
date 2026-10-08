@testable import MarkdownUI
import XCTest

final class KebabCaseTests: XCTestCase {
    func testHeadingIdentifiersKeepTheirExistingSlugs() {
        // Outputs recorded from the previous components(separatedBy:)-based implementation.
        let expectations: [(String, String)] = [
            ("", ""),
            (" ", "-"),
            ("Hello World", "hello-world"),
            ("Hello, World!", "hello--world-"),
            ("  leading and trailing  ", "--leading-and-trailing--"),
            ("a--b", "a--b"),
            ("MarkdownUI 2.0 — What's New?", "markdownui-2-0---what-s-new-"),
            ("snake_case-and-kebab", "snake-case-and-kebab"),
            ("C++ & Swift", "c-----swift"),
            ("Tab\tNew\nLine", "tab-new-line"),
            ("Ünïcödé Çafé", "ünïcödé-çafé"),
            ("e\u{301}cole", "e\u{301}cole"),
            ("ΟΔΟΣ ΑΒ", "οδοσ-αβ"),
            ("İstanbul", "i\u{307}stanbul"),
            ("straße STRASSE", "straße-strasse"),
            ("ǅungla", "ǆungla"),
            ("Ⅻ roman", "ⅻ-roman"),
            ("x²+y²", "x²-y²"),
            ("𝐀𝐁𝐂 math", "𝐀𝐁𝐂-math"),
            ("日本語 タイトル", "日本語-タイトル"),
            ("١٢٣ عربي", "١٢٣-عربي"),
            ("🚀 Launch 🚀", "--launch--"),
            ("👍🏽 ok", "---ok"),
            ("🇫🇷 France", "---france"),
            ("a\u{200D}b", "a-b"),
            ("\u{FEFF}bom", "-bom")
        ]
        for (input, expected) in expectations {
            XCTAssertEqual(input.kebabCased(), expected, input.debugDescription)
        }
    }
}
