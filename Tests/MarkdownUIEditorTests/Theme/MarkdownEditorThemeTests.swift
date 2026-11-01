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

    func testGitHubAndDocCHeadingAndLinkColorsAdaptToDarkMode() throws {
        let colors: [(name: String, color: PlatformColor?)] = [
            ("GitHub heading", MarkdownEditorTheme.gitHub.headingAttributes[.one]?[.foregroundColor] as? PlatformColor),
            ("GitHub link", MarkdownEditorTheme.gitHub.linkAttributes[.foregroundColor] as? PlatformColor),
            ("DocC heading", MarkdownEditorTheme.docC.headingAttributes[.one]?[.foregroundColor] as? PlatformColor),
            ("DocC link", MarkdownEditorTheme.docC.linkAttributes[.foregroundColor] as? PlatformColor)
        ]
        for (name, color) in colors {
            let color = try XCTUnwrap(color, name)
            let light = try XCTUnwrap(sRGBComponents(of: color, dark: false), name)
            let dark = try XCTUnwrap(sRGBComponents(of: color, dark: true), name)
            let lightBackground = try XCTUnwrap(sRGBComponents(of: defaultBackgroundColor, dark: false))
            let darkBackground = try XCTUnwrap(sRGBComponents(of: defaultBackgroundColor, dark: true))
            XCTAssertGreaterThanOrEqual(contrastRatio(light, lightBackground), 4.5, "\(name) in light mode")
            XCTAssertGreaterThanOrEqual(contrastRatio(dark, darkBackground), 4.5, "\(name) in dark mode")
            XCTAssertNotEqual(light, dark, "\(name) resolves differently in light and dark mode")
        }
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

/// The WCAG 2 contrast ratio between two sRGB colors.
private func contrastRatio(_ first: [CGFloat], _ second: [CGFloat]) -> CGFloat {
    func luminance(_ components: [CGFloat]) -> CGFloat {
        let linear = components.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
    let (lighter, darker) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
    return (lighter + 0.05) / (darker + 0.05)
}

#if canImport(UIKit)
    /// The background a `UITextView`-based editor draws behind its text.
    @MainActor private let defaultBackgroundColor = UIColor.systemBackground

    private func sRGBComponents(of color: UIColor, dark: Bool) -> [CGFloat]? {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
        return sRGB.flatMap { resolved.cgColor.converted(to: $0, intent: .defaultIntent, options: nil)?.components }
    }
#elseif canImport(AppKit)
    /// The background an `NSTextView`-based editor draws behind its text.
    @MainActor private let defaultBackgroundColor = NSColor.textBackgroundColor

    private func sRGBComponents(of color: NSColor, dark: Bool) -> [CGFloat]? {
        var components: [CGFloat]?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            guard let sRGB = color.usingColorSpace(.sRGB) else {
                return
            }
            components = [sRGB.redComponent, sRGB.greenComponent, sRGB.blueComponent]
        }
        return components
    }
#endif

#if canImport(UIKit)
    private typealias PlatformColor = UIColor
    private typealias PlatformFont = UIFont
#elseif canImport(AppKit)
    private typealias PlatformColor = NSColor
    private typealias PlatformFont = NSFont
#endif
