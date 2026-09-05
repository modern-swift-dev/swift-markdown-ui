import SwiftUI

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) struct FlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    struct Cache {
        struct Key: Equatable {
            let proposal: ProposedViewSize
            let horizontalSpacing: CGFloat
            let verticalSpacing: CGFloat
        }

        private var key: Key?
        private var rows: [Row] = []

        mutating func rows(for key: Key, compute: () -> [Row]) -> [Row] {
            if self.key != key {
                self.rows = compute()
                self.key = key
            }
            return self.rows
        }
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // Loaded images and environment changes may alter intrinsic size at the same proposal.
        cache = Cache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let rows = self.rows(for: proposal, subviews: subviews, cache: &cache)
        return self.sizeThatFits(rows: rows)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) {
        let rows = self.rows(for: proposal, subviews: subviews, cache: &cache)
        var position = bounds.origin

        for row in rows {
            for item in row.items {
                // align to bottom
                let itemBounds = CGRect(origin: position, size: item.size)
                    .offsetBy(dx: 0, dy: row.size.height - item.size.height)
                subviews[item.index].place(at: itemBounds.origin, proposal: .init(itemBounds.size))
                position.x += item.size.width + self.horizontalSpacing
            }

            position.x = bounds.origin.x
            position.y += row.size.height + self.verticalSpacing
        }
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) extension FlowLayout {
    struct Item {
        let index: Int
        let size: CGSize
    }

    struct Row {
        var size: CGSize = .zero
        var items: [Item] = []
    }

    private func rows(for proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> [Row] {
        cache.rows(for: .init(proposal: proposal, horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing)) {
            self.computeLayout(for: proposal, subviews: subviews)
        }
    }

    private func computeLayout(for proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var currentRow = Row()

        for (index, view) in zip(subviews.indices, subviews) {
            // propose the remainder of the width for low prioriy views, otherwise the full width
            // this way we can use a spacer view for hard line breaks
            let proposedWidth =
                view.priority < 0 ? proposal.width.map { $0 - currentRow.size.width } : proposal.width
            let item = Item(
                index: index,
                size: view.sizeThatFits(.init(width: proposedWidth, height: nil))
            )

            if currentRow.size.width > 0,
               currentRow.size.width + item.size.width > (proposal.width ?? .infinity) {
                // Remove the spacing for the last item
                currentRow.size.width -= self.horizontalSpacing
                rows.append(currentRow)
                currentRow = Row()
            }

            currentRow.items.append(item)
            currentRow.size.width += item.size.width + self.horizontalSpacing
            currentRow.size.height = max(item.size.height, currentRow.size.height)
        }

        if !currentRow.items.isEmpty {
            // Remove the spacing for the last item
            currentRow.size.width -= self.horizontalSpacing
            rows.append(currentRow)
        }

        return rows
    }

    private func sizeThatFits(rows: [Row]) -> CGSize {
        zip(rows.indices, rows).reduce(CGSize.zero) { size, tuple in
            let (index, row) = tuple
            let spacing = index < rows.endIndex - 1 ? self.verticalSpacing : 0
            return CGSize(
                width: max(size.width, row.size.width),
                height: size.height + row.size.height + spacing
            )
        }
    }
}
