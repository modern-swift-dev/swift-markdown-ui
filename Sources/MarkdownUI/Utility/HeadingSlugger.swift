import Foundation

/// Generates heading identifiers the way GitHub generates Markdown heading anchors.
///
/// The rules follow github-slugger: lowercase the text, remove punctuation, symbols,
/// controls and separators other than a space, then turn each space into a hyphen.
/// Repeated identifiers get `-1`, `-2`, … suffixes in document order.
/// `MarkdownUIEditor` implements the same rules; a shared test corpus keeps them in sync.
struct HeadingSlugger {
    private var occurrences: [String: Int] = [:]

    /// Returns the unique identifier for the next heading with the given plain text.
    mutating func identifier(for text: String) -> String {
        let slug = Self.slug(text)
        var identifier = slug
        while self.occurrences[identifier] != nil {
            let count = self.occurrences[slug, default: 0] + 1
            self.occurrences[slug] = count
            identifier = "\(slug)-\(count)"
        }
        self.occurrences[identifier] = 0
        return identifier
    }

    /// Returns the identifier for the text without a duplicate suffix.
    static func slug(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if scalar == " " {
                result.append("-")
            } else if scalar == "-" || scalar.properties.isAlphabetic || !removedCategories.contains(scalar.properties.generalCategory) {
                result.append(scalar)
            }
        }
        return String(result)
    }
}

/// General categories GitHub removes from identifiers unless the scalar is alphabetic.
private let removedCategories: Set<Unicode.GeneralCategory> = [
    .otherNumber,
    .closePunctuation, .finalPunctuation, .initialPunctuation, .openPunctuation, .otherPunctuation, .dashPunctuation,
    .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
    .control, .privateUse, .format, .unassigned,
    .spaceSeparator, .lineSeparator, .paragraphSeparator
]
