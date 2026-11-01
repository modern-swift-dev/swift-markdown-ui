import SwiftUI

struct HeadingView: View {
    @Environment(\.theme.headings) private var headings

    private let level: Int
    private let content: [InlineNode]
    private let identifier: String?

    init(level: Int, content: [InlineNode], identifier: String?) {
        self.level = level
        self.content = content
        self.identifier = identifier
    }

    var body: some View {
        self.headings[self.level - 1].makeBody(
            configuration: .init(
                label: .init(InlineText(self.content)),
                content: .init(configurationBlock: .heading(level: self.level, content: self.content))
            )
        )
        .id(self.identifier ?? HeadingSlugger.slug(self.content.renderHeadingText()))
        .accessibilityAddTraits(.isHeader)
        .accessibilityHeading(AccessibilityHeadingLevel(markdownLevel: self.level))
    }
}

extension AccessibilityHeadingLevel {
    /// The heading level that assistive technologies use to navigate a Markdown heading of `level` 1–6.
    init(markdownLevel level: Int) {
        self = AccessibilityHeadingLevel(rawValue: UInt(clamping: level)) ?? .unspecified
    }
}
