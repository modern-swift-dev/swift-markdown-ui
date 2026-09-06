import Foundation
@testable import MarkdownUIEditor
import XCTest

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

@MainActor final class MarkdownEditorThemeTests: XCTestCase {
    func testPresetsUseDifferentLinkColors() throws {
        let basic = try XCTUnwrap(MarkdownEditorTheme.basic.linkAttributes[.foregroundColor] as? PlatformColor)
        let gitHub = try XCTUnwrap(MarkdownEditorTheme.gitHub.linkAttributes[.foregroundColor] as? PlatformColor)
        let docC = try XCTUnwrap(MarkdownEditorTheme.docC.linkAttributes[.foregroundColor] as? PlatformColor)

        XCTAssertNotEqual(basic, gitHub)
        XCTAssertNotEqual(gitHub, docC)
    }

    func testProjectionAppliesHeadingCodeAndLinkRoles() {
        let theme = MarkdownEditorTheme.docC
        let projection = MarkdownProjectionBuilder().build(
            document: MarkdownDocument(blocks: [
                .heading(level: .two, content: [.text("Heading")]),
                .paragraph([.code("code"), .text(" "), .link(destination: "/guide", title: nil, children: [.text("link")])])
            ]),
            theme: theme
        )

        let headingRange = (projection.string as NSString).range(of: "Heading")
        let codeRange = (projection.string as NSString).range(of: "code")
        let linkRange = (projection.string as NSString).range(of: "link")

        XCTAssertEqual(
            projection.attributedString.attribute(.font, at: headingRange.location, effectiveRange: nil) as? PlatformFont,
            theme.headingAttributes[.two]?[.font] as? PlatformFont
        )
        XCTAssertEqual(
            projection.attributedString.attribute(.font, at: codeRange.location, effectiveRange: nil) as? PlatformFont,
            theme.codeAttributes[.font] as? PlatformFont
        )
        XCTAssertEqual(
            projection.attributedString.attribute(.foregroundColor, at: linkRange.location, effectiveRange: nil) as? PlatformColor,
            theme.linkAttributes[.foregroundColor] as? PlatformColor
        )
    }
}

#if canImport(UIKit)
    private typealias PlatformColor = UIColor
    private typealias PlatformFont = UIFont
#elseif canImport(AppKit)
    private typealias PlatformColor = NSColor
    private typealias PlatformFont = NSFont
#endif
