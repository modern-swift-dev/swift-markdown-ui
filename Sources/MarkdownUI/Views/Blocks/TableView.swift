import SwiftUI

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) struct TableView: View {
    @Environment(\.theme.table) private var table
    @Environment(\.tableBorderStyle.strokeStyle.lineWidth) private var inheritedBorderWidth

    private let columnAlignments: [RawTableColumnAlignment]
    private let rows: [RawTableRow]

    init(columnAlignments: [RawTableColumnAlignment], rows: [RawTableRow]) {
        self.columnAlignments = columnAlignments
        self.rows = rows
    }

    var body: some View {
        self.table.makeBody(
            configuration: .init(
                label: .init(TableLayout(
                    columnAlignments: self.columnAlignments, rows: self.rows,
                    inheritedBorderWidth: self.inheritedBorderWidth
                )),
                content: .init(configurationBlock: .table(columnAlignments: self.columnAlignments, rows: self.rows))
            )
        )
    }

}

private struct TableLayout: View {
    @Environment(\.tableBorderStyle) private var borderStyle
    @Environment(\.markdownBlockRenderingMode) private var renderingMode
    @Environment(\.tableColumnWidths) private var tableColumnWidths

    let columnAlignments: [RawTableColumnAlignment]
    let rows: [RawTableRow]
    let inheritedBorderWidth: CGFloat

    var body: some View {
        if case .lazyContainers = self.renderingMode,
           let widths = self.columnWidths,
           self.supportsLazyRows {
            LazyTableView(columnAlignments: self.columnAlignments, rows: self.rows, columnWidths: widths)
        } else {
            self.eagerLabel
        }
    }

    private var eagerLabel: some View {
        Grid(horizontalSpacing: self.eagerBorderWidth, verticalSpacing: self.eagerBorderWidth) {
            ForEach(0 ..< self.rowCount, id: \.self) { row in
                GridRow {
                    ForEach(0 ..< self.columnCount, id: \.self) { column in
                        TableCell(
                            row: row, column: column, cell: self.rows[row].cells[column],
                            width: self.columnWidths?[column], alignment: .init(self.columnAlignments[column])
                        )
                        .gridColumnAlignment(.init(self.columnAlignments[column]))
                    }
                }
            }
        }
        .padding(self.eagerBorderWidth)
        .tableDecoration(
            rowCount: self.rowCount,
            columnCount: self.columnCount,
            background: TableBackgroundView.init,
            overlay: TableBorderView.init
        )
    }

    private var borderWidth: CGFloat {
        self.borderStyle.strokeStyle.lineWidth
    }

    private var eagerBorderWidth: CGFloat {
        // Intrinsic tables preserve the spacing captured before the table theme
        // wraps its label. Explicit-width layouts use the label's configuration.
        self.columnWidths == nil ? self.inheritedBorderWidth : self.borderWidth
    }

    private var supportsLazyRows: Bool {
        self.borderStyle.visibleBorders.components != nil
            && self.borderWidth.isFinite && self.borderWidth > 0
            && self.borderWidth.rounded() == self.borderWidth
            && self.borderStyle.strokeStyle == StrokeStyle(lineWidth: self.borderWidth)
    }

    private var columnWidths: [CGFloat]? {
        guard let widths = self.tableColumnWidths, widths.count == self.columnCount else {
            return nil
        }
        return widths
    }

    private var rowCount: Int {
        self.rows.count
    }

    private var columnCount: Int {
        self.columnAlignments.count
    }
}

extension HorizontalAlignment {
    init(_ rawTableColumnAlignment: RawTableColumnAlignment) {
        switch rawTableColumnAlignment {
            case .none,
                 .left:
                self = .leading
            case .center:
                self = .center
            case .right:
                self = .trailing
        }
    }
}
