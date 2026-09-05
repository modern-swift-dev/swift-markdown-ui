import SwiftUI

struct TableBounds: Sendable {
    var rowCount: Int {
        self.rows.count
    }

    var columnCount: Int {
        self.columns.count
    }

    let bounds: CGRect

    private let rows: [(minY: CGFloat, height: CGFloat)]
    private let columns: [(minX: CGFloat, width: CGFloat)]
    private let columnExtent: (minX: CGFloat, maxX: CGFloat)
    private let rowExtent: (minY: CGFloat, maxY: CGFloat)

    fileprivate init(
        rowCount: Int,
        columnCount: Int,
        anchors: [TableCellIndex: Anchor<CGRect>],
        proxy: GeometryProxy
    ) {
        self.init(rowCount: rowCount, columnCount: columnCount, bounds: proxy.frame(in: .local)) { row, column in
            anchors[TableCellIndex(row: row, column: column)].map { proxy[$0] }
        }
    }

    init(
        rowCount: Int,
        columnCount: Int,
        bounds: CGRect,
        cellBounds: (_ row: Int, _ column: Int) -> CGRect?
    ) {
        var rows = Array(
            repeating: (minY: CGFloat.greatestFiniteMagnitude, height: CGFloat(0)),
            count: rowCount
        )
        var columns = Array(
            repeating: (minX: CGFloat.greatestFiniteMagnitude, width: CGFloat(0)),
            count: columnCount
        )

        for row in 0 ..< rowCount {
            for column in 0 ..< columnCount {
                guard let bounds = cellBounds(row, column) else {
                    continue
                }

                rows[row].minY = min(rows[row].minY, bounds.minY)
                rows[row].height = max(rows[row].height, bounds.height)

                columns[column].minX = min(columns[column].minX, bounds.minX)
                columns[column].width = max(columns[column].width, bounds.width)
            }
        }

        self.bounds = bounds
        self.rows = rows
        self.columns = columns
        self.columnExtent = columns.reduce((minX: CGFloat.greatestFiniteMagnitude, maxX: -CGFloat.greatestFiniteMagnitude)) {
            (min($0.minX, $1.minX), max($0.maxX, $1.minX + $1.width))
        }
        self.rowExtent = rows.reduce((minY: CGFloat.greatestFiniteMagnitude, maxY: -CGFloat.greatestFiniteMagnitude)) {
            (min($0.minY, $1.minY), max($0.maxY, $1.minY + $1.height))
        }
    }

    func bounds(forRow row: Int, column: Int) -> CGRect {
        CGRect(
            origin: .init(x: self.columns[column].minX, y: self.rows[row].minY),
            size: .init(width: self.columns[column].width, height: self.rows[row].height)
        )
    }

    func bounds(forRow row: Int) -> CGRect {
        guard !self.columns.isEmpty else {
            return .null
        }
        return CGRect(
            x: self.columnExtent.minX,
            y: self.rows[row].minY,
            width: self.columnExtent.maxX - self.columnExtent.minX,
            height: self.rows[row].height
        )
    }

    func bounds(forColumn column: Int) -> CGRect {
        guard !self.rows.isEmpty else {
            return .null
        }
        return CGRect(
            x: self.columns[column].minX,
            y: self.rowExtent.minY,
            width: self.columns[column].width,
            height: self.rowExtent.maxY - self.rowExtent.minY
        )
    }
}

extension View {
    func tableCellBounds(forRow row: Int, column: Int) -> some View {
        self.anchorPreference(key: TableCellBoundsPreference.self, value: .bounds) { anchor in
            [TableCellIndex(row: row, column: column): anchor]
        }
    }

    func tableDecoration(
        rowCount: Int,
        columnCount: Int,
        background: @escaping (TableBounds) -> some View,
        overlay: @escaping (TableBounds) -> some View
    ) -> some View {
        self
            .backgroundPreferenceValue(TableCellBoundsPreference.self) { anchors in
                GeometryReader { proxy in
                    let bounds = TableBounds(
                        rowCount: rowCount,
                        columnCount: columnCount,
                        anchors: anchors,
                        proxy: proxy
                    )
                    background(bounds)
                        .preference(key: ResolvedTableBoundsPreference.self, value: bounds)
                }
            }
            .overlayPreferenceValue(ResolvedTableBoundsPreference.self) { bounds in
                if let bounds {
                    GeometryReader { _ in
                        overlay(bounds)
                    }
                }
            }
            // Resolved coordinates belong to this table, not an enclosing decoration.
            .transformPreference(ResolvedTableBoundsPreference.self) { $0 = nil }
    }
}

private struct TableCellIndex: Hashable {
    var row: Int
    var column: Int
}

private struct ResolvedTableBoundsPreference: PreferenceKey {
    static let defaultValue: TableBounds? = nil

    static func reduce(value: inout TableBounds?, nextValue: () -> TableBounds?) {
        if let next = nextValue() {
            value = next
        }
    }
}

private struct TableCellBoundsPreference: PreferenceKey {
    static let defaultValue: [TableCellIndex: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [TableCellIndex: Anchor<CGRect>],
        nextValue: () -> [TableCellIndex: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { $1 }
    }
}
