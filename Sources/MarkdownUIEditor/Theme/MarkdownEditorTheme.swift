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
    /// Whether the editor scales this theme's fonts with the content size category (Dynamic Type).
    ///
    /// On iOS, iPadOS, and Mac Catalyst, the fonts are the sizes used at the default
    /// (Large) content size category. The editor scales every font by the factor the
    /// system body text style scales by, so body text matches the system body size and
    /// the other fonts keep their sizes relative to it. It renders again when the text
    /// size changes. AppKit has no content size category, so macOS ignores this property.
    public let adjustsFontForContentSizeCategory: Bool

    /// Creates a theme from the attributes used by each projected content category.
    ///
    /// Pass `true` for `adjustsFontForContentSizeCategory` to scale the fonts with
    /// Dynamic Type on UIKit. Give fonts of a fixed size then, such as
    /// `UIFont.systemFont(ofSize:)`, because the editor does the scaling.
    public init(
        bodyAttributes: [NSAttributedString.Key: Any],
        headingAttributes: [MarkdownHeadingLevel: [NSAttributedString.Key: Any]],
        codeAttributes: [NSAttributedString.Key: Any],
        sourceAttributes: [NSAttributedString.Key: Any],
        linkAttributes: [NSAttributedString.Key: Any],
        objectPlaceholderAttributes: [NSAttributedString.Key: Any],
        adjustsFontForContentSizeCategory: Bool = false
    ) {
        self.bodyAttributes = bodyAttributes
        self.headingAttributes = headingAttributes
        self.codeAttributes = codeAttributes
        self.sourceAttributes = sourceAttributes
        self.linkAttributes = linkAttributes
        self.objectPlaceholderAttributes = objectPlaceholderAttributes
        self.adjustsFontForContentSizeCategory = adjustsFontForContentSizeCategory
    }

    /// A system-colored theme with standard body, heading, and code fonts.
    public static var basic: MarkdownEditorTheme {
        MarkdownEditorTheme(
            bodyAttributes: bodyAttributes(color: labelColor),
            headingAttributes: headingAttributes(color: labelColor),
            codeAttributes: codeAttributes(color: labelColor),
            sourceAttributes: codeAttributes(color: labelColor),
            linkAttributes: [.foregroundColor: linkColor],
            objectPlaceholderAttributes: bodyAttributes(color: secondaryLabelColor),
            adjustsFontForContentSizeCategory: true
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
            objectPlaceholderAttributes: bodyAttributes(color: secondaryLabelColor),
            adjustsFontForContentSizeCategory: true
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
            objectPlaceholderAttributes: bodyAttributes(color: secondaryLabelColor),
            adjustsFontForContentSizeCategory: true
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

#if os(iOS) || targetEnvironment(macCatalyst)
    extension MarkdownEditorTheme {
        /// This theme with every font scaled to `category`, or the theme itself when it
        /// doesn't adjust fonts for the content size category.
        func scaled(to category: UIContentSizeCategory) -> MarkdownEditorTheme {
            guard adjustsFontForContentSizeCategory else {
                return self
            }
            func bodySize(_ category: UIContentSizeCategory) -> CGFloat {
                UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: category)).pointSize
            }
            let scale = bodySize(category) / bodySize(.large)
            func scaled(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
                guard let font = attributes[.font] as? UIFont else {
                    return attributes
                }
                var attributes = attributes
                attributes[.font] = font.withSize(font.pointSize * scale)
                return attributes
            }
            return MarkdownEditorTheme(
                bodyAttributes: scaled(bodyAttributes),
                headingAttributes: headingAttributes.mapValues(scaled),
                codeAttributes: scaled(codeAttributes),
                sourceAttributes: scaled(sourceAttributes),
                linkAttributes: scaled(linkAttributes),
                objectPlaceholderAttributes: scaled(objectPlaceholderAttributes)
            )
        }
    }
#endif

/// sRGB components of a fixed theme color, each between 0 and 1.
private typealias RGB = (red: CGFloat, green: CGFloat, blue: CGFloat)

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

        /// Created once: dynamic colors compare by identity, and equivalent themes must compare equal.
        static let gitHubLinkColor = color(light: (0.03, 0.35, 0.73), dark: (0.27, 0.58, 0.97))

        static let docCHeadingColor = color(light: (0.22, 0.25, 0.31), dark: (0.87, 0.89, 0.93))

        static let docCLinkColor = color(light: (0.34, 0.20, 0.78), dark: (0.68, 0.58, 1.0))

        /// A color that resolves to `dark` in dark mode.
        static func color(light: RGB, dark: RGB) -> UIColor {
            UIColor { traits in
                let rgb = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
            }
        }

        static func preferredBodyFont() -> UIFont {
            #if os(iOS) || targetEnvironment(macCatalyst)
                // The editor scales built-in themes, so they start from the default text size.
                UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
            #else
                UIFont.preferredFont(forTextStyle: .body)
            #endif
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

        /// Created once: dynamic colors compare by identity, and equivalent themes must compare equal.
        static let gitHubLinkColor = color(light: (0.03, 0.35, 0.73), dark: (0.27, 0.58, 0.97))

        static let docCHeadingColor = color(light: (0.22, 0.25, 0.31), dark: (0.87, 0.89, 0.93))

        static let docCLinkColor = color(light: (0.34, 0.20, 0.78), dark: (0.68, 0.58, 1.0))

        /// A color that resolves to `dark` in dark appearances.
        static func color(light: RGB, dark: RGB) -> NSColor {
            NSColor(name: nil) { appearance in
                let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
            }
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
