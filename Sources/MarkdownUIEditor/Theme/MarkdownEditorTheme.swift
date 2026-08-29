import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Attributes used when projecting a `MarkdownDocument` into native rich text.
@MainActor public final class MarkdownEditorTheme {
    /// Attributes for ordinary paragraph text.
    public let bodyAttributes: [NSAttributedString.Key: Any]
    /// Attributes keyed by heading level.
    public let headingAttributes: [MarkdownHeadingLevel: [NSAttributedString.Key: Any]]
    /// Attributes for rendered code content.
    public let codeAttributes: [NSAttributedString.Key: Any]
    /// Attributes for source-like content, such as HTML and code markers.
    public let sourceAttributes: [NSAttributedString.Key: Any]
    /// Attributes applied to linked text.
    public let linkAttributes: [NSAttributedString.Key: Any]
    /// Attributes for table and image placeholders when their native view is unavailable.
    public let objectPlaceholderAttributes: [NSAttributedString.Key: Any]

    /// Creates a theme from the attributes used by each projected content category.
    public init(
        bodyAttributes: [NSAttributedString.Key: Any],
        headingAttributes: [MarkdownHeadingLevel: [NSAttributedString.Key: Any]],
        codeAttributes: [NSAttributedString.Key: Any],
        sourceAttributes: [NSAttributedString.Key: Any],
        linkAttributes: [NSAttributedString.Key: Any],
        objectPlaceholderAttributes: [NSAttributedString.Key: Any]
    ) {
        self.bodyAttributes = bodyAttributes
        self.headingAttributes = headingAttributes
        self.codeAttributes = codeAttributes
        self.sourceAttributes = sourceAttributes
        self.linkAttributes = linkAttributes
        self.objectPlaceholderAttributes = objectPlaceholderAttributes
    }

    /// A system-colored theme with standard body, heading, and code fonts.
    public static var basic: MarkdownEditorTheme {
        MarkdownEditorTheme(
            bodyAttributes: bodyAttributes(color: labelColor),
            headingAttributes: headingAttributes(color: labelColor),
            codeAttributes: codeAttributes(color: labelColor),
            sourceAttributes: codeAttributes(color: labelColor),
            linkAttributes: [.foregroundColor: linkColor],
            objectPlaceholderAttributes: bodyAttributes(color: secondaryLabelColor)
        )
    }

    /// A system-font theme with GitHub's blue link color.
    public static var gitHub: MarkdownEditorTheme {
        MarkdownEditorTheme(
            bodyAttributes: bodyAttributes(color: labelColor),
            headingAttributes: headingAttributes(color: labelColor),
            codeAttributes: codeAttributes(color: labelColor),
            sourceAttributes: codeAttributes(color: labelColor),
            linkAttributes: [.foregroundColor: gitHubLinkColor],
            objectPlaceholderAttributes: bodyAttributes(color: secondaryLabelColor)
        )
    }

    /// A system-font theme with DocC-inspired heading and link colors.
    public static var docC: MarkdownEditorTheme {
        MarkdownEditorTheme(
            bodyAttributes: bodyAttributes(color: labelColor),
            headingAttributes: headingAttributes(color: docCHeadingColor),
            codeAttributes: codeAttributes(color: labelColor),
            sourceAttributes: codeAttributes(color: labelColor),
            linkAttributes: [.foregroundColor: docCLinkColor],
            objectPlaceholderAttributes: bodyAttributes(color: secondaryLabelColor)
        )
    }
}

private extension MarkdownEditorTheme {
    static func bodyAttributes(color: PlatformColor) -> [NSAttributedString.Key: Any] {
        [.font: preferredBodyFont(), .foregroundColor: color]
    }

    static func headingAttributes(color: PlatformColor) -> [MarkdownHeadingLevel: [NSAttributedString.Key: Any]] {
        Dictionary(uniqueKeysWithValues: MarkdownHeadingLevel.allCases.map { level in
            let size = preferredBodyFont().pointSize + CGFloat(7 - level.rawValue) * 2
            return (level, [.font: systemFont(size: size, weight: .bold), .foregroundColor: color])
        })
    }

    static func codeAttributes(color: PlatformColor) -> [NSAttributedString.Key: Any] {
        [.font: monospacedFont(size: preferredBodyFont().pointSize, weight: .regular), .foregroundColor: color]
    }
}

#if canImport(UIKit)
private typealias PlatformColor = UIColor

private extension MarkdownEditorTheme {
    static var labelColor: UIColor {
        .label
    }

    static var secondaryLabelColor: UIColor {
        .secondaryLabel
    }

    static var linkColor: UIColor {
        .link
    }

    static var gitHubLinkColor: UIColor {
        UIColor(red: 0.03, green: 0.35, blue: 0.73, alpha: 1)
    }

    static var docCHeadingColor: UIColor {
        UIColor(red: 0.22, green: 0.25, blue: 0.31, alpha: 1)
    }

    static var docCLinkColor: UIColor {
        UIColor(red: 0.34, green: 0.20, blue: 0.78, alpha: 1)
    }

    static func preferredBodyFont() -> UIFont {
        UIFont.preferredFont(forTextStyle: .body)
    }

    static func systemFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: weight)
    }

    static func monospacedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}
#elseif canImport(AppKit)
private typealias PlatformColor = NSColor

private extension MarkdownEditorTheme {
    static var labelColor: NSColor {
        .labelColor
    }

    static var secondaryLabelColor: NSColor {
        .secondaryLabelColor
    }

    static var linkColor: NSColor {
        .linkColor
    }

    static var gitHubLinkColor: NSColor {
        NSColor(red: 0.03, green: 0.35, blue: 0.73, alpha: 1)
    }

    static var docCHeadingColor: NSColor {
        NSColor(red: 0.22, green: 0.25, blue: 0.31, alpha: 1)
    }

    static var docCLinkColor: NSColor {
        NSColor(red: 0.34, green: 0.20, blue: 0.78, alpha: 1)
    }

    static func preferredBodyFont() -> NSFont {
        NSFont.preferredFont(forTextStyle: .body)
    }

    static func systemFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func monospacedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}
#endif
