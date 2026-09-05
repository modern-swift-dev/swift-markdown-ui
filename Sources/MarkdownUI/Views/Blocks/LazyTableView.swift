import SwiftUI

/// Explicit column widths let rows be measured independently without scanning
/// offscreen cells to determine a shared intrinsic column width.
struct LazyTableView: View {
    @Environment(\.tableBorderStyle) private var borderStyle
    @Environment(\.tableBackgroundStyle) private var backgroundStyle
    @Environment(\.layoutDirection) private var layoutDirection

    let columnAlignments: [RawTableColumnAlignment]
    let rows: [RawTableRow]
    let columnWidths: [CGFloat]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: self.borderWidth) {
            ForEach(self.rows.indices, id: \.self) { row in
                self.row(at: row)
            }
        }
        .frame(width: self.columnWidths.reduce(0, +) + CGFloat(self.columnWidths.count - 1) * self.borderWidth)
        .padding(self.borderWidth)
        .overlayPreferenceValue(LazyTableRowGeometryPreference.self) { geometries in
            GeometryReader { proxy in
                let resolved = geometries.compactMapValues { geometry -> ResolvedLazyTableRowGeometry? in
                    guard let anchor = geometry.anchor else {
                        return nil
                    }
                    return .init(bounds: geometry.bounds, origin: proxy[anchor].origin)
                }
                TableBorderView(tableBounds: self.globalBounds(size: proxy.size, rows: resolved))
                    .environment(\.tableBorderStyle, self.globalBorderStyle(rows: resolved))
            }
        }
        .transformPreference(LazyTableRowGeometryPreference.self) { $0 = [:] }
    }

    private func row(at row: Int) -> some View {
        Grid(horizontalSpacing: self.borderWidth, verticalSpacing: 0) {
            GridRow {
                ForEach(self.columnWidths.indices, id: \.self) { column in
                    TableCell(
                        row: row, column: column, cell: self.rows[row].cells[column],
                        width: self.columnWidths[column], alignment: .init(self.columnAlignments[column]),
                        boundsRow: 0
                    )
                    .gridColumnAlignment(.init(self.columnAlignments[column]))
                }
            }
        }
        .tableDecoration(
            rowCount: 1,
            columnCount: self.columnWidths.count,
            background: { bounds in
                TableBackgroundView(tableBounds: bounds)
                    .environment(\.tableBackgroundStyle, self.backgroundStyle(for: row))
                    .preference(key: LazyTableRowGeometryPreference.self, value: [row: .init(bounds: bounds)])
            },
            overlay: { _ in EmptyView() }
        )
        .transformAnchorPreference(key: LazyTableRowGeometryPreference.self, value: .bounds) { geometries, anchor in
            geometries[row]?.anchor = anchor
        }
    }

    private var borderWidth: CGFloat {
        self.borderStyle.strokeStyle.lineWidth
    }

    private func backgroundStyle(for row: Int) -> TableBackgroundStyle {
        switch self.backgroundStyle.background {
            case .clear:
                .clear
            case let .custom(background):
                TableBackgroundStyle { _, column in background(row, column) }
        }
    }

    private func globalBorderStyle(rows: [Int: ResolvedLazyTableRowGeometry]) -> TableBorderStyle {
        let components = self.borderStyle.visibleBorders.components ?? []
        let horizontalRows = rows.keys.sorted().filter { $0 < self.rows.count - 1 }.compactMap { rows[$0]?.rowBounds }
        let selector = TableBorderSelector { bounds, width in
            var rectangles: [CGRect] = []
            if components.contains(.outsideHorizontal) {
                // The synthetic bounds contain one row, so horizontalBorders
                // emits only the outer top and bottom rectangles.
                rectangles += TableBorderSelector.horizontalBorders.rectangles(bounds, width)
            }
            if components.contains(.insideHorizontal) {
                rectangles += horizontalRows.map { row in
                    let expanded = row.insetBy(dx: -width, dy: -width)
                    return CGRect(x: expanded.minX, y: expanded.maxY - width, width: expanded.width, height: width)
                }
            }
            if components.contains(.insideVertical) {
                rectangles += TableBorderSelector.insideVerticalBorders.rectangles(bounds, width)
            }
            if components.contains(.outside) {
                rectangles += TableBorderSelector.outsideBorders.rectangles(bounds, width)
            }
            return rectangles
        }
        return TableBorderStyle(selector, color: self.borderStyle.color, strokeStyle: self.borderStyle.strokeStyle)
    }

    private func globalBounds(size: CGSize, rows: [Int: ResolvedLazyTableRowGeometry]) -> TableBounds {
        let first = rows[0]?.rowBounds.minY ?? self.borderWidth
        let last = rows[self.rows.count - 1]?.rowBounds.maxY ?? size.height - self.borderWidth
        let sample = rows.values.first
        var offset = self.borderWidth
        return TableBounds(
            rowCount: 1, columnCount: self.columnWidths.count,
            bounds: CGRect(origin: .zero, size: size)
        ) { _, column in
            let width = self.columnWidths[column]
            let estimatedX = self.layoutDirection == .rightToLeft ? size.width - offset - width : offset
            offset += width + self.borderWidth
            let columnBounds = sample.map {
                $0.bounds.bounds(forColumn: column).offsetBy(dx: $0.origin.x, dy: $0.origin.y)
            }
            return CGRect(
                x: columnBounds?.minX ?? estimatedX,
                y: first,
                width: columnBounds?.width ?? width,
                height: max(0, last - first)
            )
        }
    }
}

private struct LazyTableRowGeometry {
    let bounds: TableBounds
    var anchor: Anchor<CGRect>?
}

private struct ResolvedLazyTableRowGeometry {
    let bounds: TableBounds
    let origin: CGPoint

    var rowBounds: CGRect {
        self.bounds.bounds(forRow: 0).offsetBy(dx: self.origin.x, dy: self.origin.y)
    }
}

private struct LazyTableRowGeometryPreference: PreferenceKey {
    static let defaultValue: [Int: LazyTableRowGeometry] = [:]

    static func reduce(value: inout [Int: LazyTableRowGeometry], nextValue: () -> [Int: LazyTableRowGeometry]) {
        value.merge(nextValue()) { $1 }
    }
}
