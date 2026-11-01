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
        .id(self.identifier ?? HeadingSlugger.slug(self.content.renderPlainText()))
        .accessibilityAddTraits(.isHeader)
    }
}
