import SwiftUI

struct ParagraphView: View {
    @Environment(\.theme.paragraph) private var paragraph

    private let content: [InlineNode]

    init(content: String) {
        self.init(
            content: [
                .text(content.hasSuffix("\n") ? String(content.dropLast()) : content)
            ]
        )
    }

    init(content: [InlineNode]) {
        self.content = content
    }

    var body: some View {
        self.paragraph.makeBody(
            configuration: .init(
                label: .init(self.label),
                content: .init(configurationBlock: .paragraph(content: self.content))
            )
        )
    }

    @ViewBuilder private var label: some View {
        if let imageView = ImageView(content) {
            imageView
        } else if let imageFlow = ImageFlow(content) {
            imageFlow
        } else {
            InlineText(content)
        }
    }
}
