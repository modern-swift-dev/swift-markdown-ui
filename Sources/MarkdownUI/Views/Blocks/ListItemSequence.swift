import SwiftUI

struct ListItemSequence: View {
    @Environment(\.markdownBlockRenderingMode) private var blockRenderingMode

    private let items: [RawListItem]
    private let start: Int
    private let markerStyle: BlockStyle<ListMarkerConfiguration>
    private let markerWidth: CGFloat?
    private let readsMarkerWidth: Bool

    /// Creates a list item sequence.
    ///
    /// Pass `readsMarkerWidth: true` to publish each marker's natural width through
    /// ``MarkerWidthPreference`` and align markers to `markerWidth`.
    init(
        items: [RawListItem],
        start: Int = 1,
        markerStyle: BlockStyle<ListMarkerConfiguration>,
        markerWidth: CGFloat? = nil,
        readsMarkerWidth: Bool = false
    ) {
        self.items = items
        self.start = start
        self.markerStyle = markerStyle
        self.markerWidth = markerWidth
        self.readsMarkerWidth = readsMarkerWidth
    }

    var body: some View {
        BlockSequence(self.items, renderingMode: self.blockRenderingMode.nestedRenderingMode) { index, item in
            ListItemView(
                item: item,
                number: self.start + index,
                markerStyle: self.markerStyle,
                markerWidth: self.markerWidth,
                readsMarkerWidth: self.readsMarkerWidth
            )
        }
        .labelStyle(.titleAndIcon)
    }
}
