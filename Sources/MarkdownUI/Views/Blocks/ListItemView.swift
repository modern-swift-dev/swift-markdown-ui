import SwiftUI

struct ListItemView: View {
    @Environment(\.theme.listItem) private var listItem
    @Environment(\.listLevel) private var listLevel
    @Environment(\.markdownBlockRenderingMode) private var blockRenderingMode

    private let item: RawListItem
    private let number: Int
    private let markerStyle: BlockStyle<ListMarkerConfiguration>
    private let markerWidth: CGFloat?
    private let readsMarkerWidth: Bool

    init(
        item: RawListItem,
        number: Int,
        markerStyle: BlockStyle<ListMarkerConfiguration>,
        markerWidth: CGFloat?,
        readsMarkerWidth: Bool
    ) {
        self.item = item
        self.number = number
        self.markerStyle = markerStyle
        self.markerWidth = markerWidth
        self.readsMarkerWidth = readsMarkerWidth
    }

    var body: some View {
        self.listItem.makeBody(
            configuration: .init(
                label: .init(self.label),
                content: .init(configurationBlocks: item.children)
            )
        )
    }

    private var label: some View {
        Label {
            if let isCompleted = self.item.isCompleted {
                TaskListItemLabel(item: .init(isCompleted: isCompleted, children: self.item.children))
            } else {
                ListItemBlocks(self.item.children, renderingMode: self.blockRenderingMode.nestedRenderingMode)
            }
        } icon: {
            let marker = self.markerStyle
                .makeBody(configuration: .init(listLevel: self.listLevel, itemNumber: self.number))
                .textStyleFont()
                .fixedSize(horizontal: true, vertical: false)

            // Only numbered lists align their markers to a shared width; bulleted
            // items skip the measuring and framing layers entirely.
            if self.readsMarkerWidth {
                marker
                    .readMarkerWidth()
                    .frame(width: self.markerWidth, alignment: .trailing)
            } else {
                marker
            }
        }
        #if os(visionOS)
        .labelStyle(BulletItemStyle())
        #endif
    }
}

/// Renders the child blocks of a list item.
///
/// Most list items contain a single block. In eager mode, a block sequence around it
/// only adds a stack and margin bookkeeping without changing the layout, so the block
/// renders directly. Its margin preferences still reach the enclosing sequence.
struct ListItemBlocks: View {
    private let children: [BlockNode]
    private let renderingMode: MarkdownBlockRenderingMode

    init(_ children: [BlockNode], renderingMode: MarkdownBlockRenderingMode) {
        self.children = children
        self.renderingMode = renderingMode
    }

    var body: some View {
        if self.renderingMode == .eager, self.children.count == 1 {
            self.children[0]
        } else {
            BlockSequence(self.children, renderingMode: self.renderingMode)
        }
    }
}

extension VerticalAlignment {
    private enum CenterOfFirstLine: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            let heightAfterFirstLine = context[.lastTextBaseline] - context[.firstTextBaseline]
            let heightOfFirstLine = context.height - heightAfterFirstLine
            return heightOfFirstLine / 2
        }
    }

    static let centerOfFirstLine = Self(CenterOfFirstLine.self)
}

struct BulletItemStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .centerOfFirstLine, spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}
