import SwiftUI

struct BlockSequence<Data: Sequence, Content: View>: View {
    @Environment(\.multilineTextAlignment) private var textAlignment
    @Environment(\.tightSpacingEnabled) private var tightSpacingEnabled

    @State private var blockMargins: [Int: BlockMargin] = [:]

    private let data: [Data.Element]
    private let renderingMode: MarkdownBlockRenderingMode
    private let content: (Int, Data.Element) -> Content

    init(
        _ data: Data,
        renderingMode: MarkdownBlockRenderingMode = .eager,
        @ViewBuilder content: @escaping (_ index: Int, _ element: Data.Element) -> Content
    ) {
        self.data = Array(data)
        self.renderingMode = renderingMode
        self.content = content
    }

    var body: some View {
        Group {
            switch self.renderingMode {
                case .eager:
                    VStack(alignment: self.textAlignment.alignment.horizontal, spacing: 0) {
                        self.rows
                    }
                case .lazy,
                     .lazyContainers:
                    LazyVStack(alignment: self.textAlignment.alignment.horizontal, spacing: 0) {
                        self.rows
                    }
            }
        }
        .onChange(of: self.data.count) { _, count in
            self.blockMargins = self.blockMargins.filter { $0.key < count }
        }
    }

    private var rows: some View {
        ForEach(self.data.indices, id: \.self) { index in
            self.content(index, self.data[index])
                .onPreferenceChange(BlockMarginsPreference.self) { value in
                    if self.blockMargins[index] != value {
                        self.blockMargins[index] = value
                    }
                }
                .padding(.top, self.topPaddingLength(at: index))
        }
    }

    private func topPaddingLength(at index: Int) -> CGFloat? {
        guard index > 0 else {
            return 0
        }

        let topSpacing = self.blockMargins[index]?.top
        let predecessorBottomSpacing =
            self.tightSpacingEnabled ? 0 : self.blockMargins[index - 1]?.bottom

        return BlockMargin.maximum(topSpacing, predecessorBottomSpacing)
    }
}

extension BlockSequence where Data == [BlockNode], Content == BlockNode {
    init(_ blocks: [BlockNode], renderingMode: MarkdownBlockRenderingMode = .eager) {
        self.init(blocks, renderingMode: renderingMode) { $1 }
    }
}

private extension TextAlignment {
    var alignment: Alignment {
        switch self {
            case .leading:
                .leading
            case .center:
                .center
            case .trailing:
                .trailing
        }
    }
}
