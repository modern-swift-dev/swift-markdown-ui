import SwiftUI

struct BlockquoteView: View {
    @Environment(\.theme.blockquote) private var blockquote
    @Environment(\.markdownBlockRenderingMode) private var blockRenderingMode

    private let children: [BlockNode]

    init(children: [BlockNode]) {
        self.children = children
    }

    var body: some View {
        self.blockquote.makeBody(
            configuration: .init(
                label: .init(BlockSequence(self.children, renderingMode: self.blockRenderingMode.nestedRenderingMode)),
                content: .init(configurationBlock: .blockquote(children: self.children))
            )
        )
    }
}
