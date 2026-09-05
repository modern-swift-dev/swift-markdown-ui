import SwiftUI

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) struct TableCell: View {
    @Environment(\.theme.tableCell) private var tableCell

    private let row: Int
    private let column: Int
    private let cell: RawTableCell
    private let width: CGFloat?
    private let alignment: HorizontalAlignment
    private let boundsRow: Int

    init(
        row: Int, column: Int, cell: RawTableCell,
        width: CGFloat? = nil, alignment: HorizontalAlignment = .center, boundsRow: Int? = nil
    ) {
        self.row = row
        self.column = column
        self.cell = cell
        self.width = width
        self.alignment = alignment
        self.boundsRow = boundsRow ?? row
    }

    var body: some View {
        self.tableCell.makeBody(
            configuration: .init(
                row: self.row,
                column: self.column,
                label: .init(self.label),
                content: .init(configurationBlock: .paragraph(content: cell.content))
            )
        )
        .frame(width: self.width, alignment: Alignment(horizontal: self.alignment, vertical: .center))
        .tableCellBounds(forRow: self.boundsRow, column: self.column)
    }

    @ViewBuilder private var label: some View {
        if let imageFlow = ImageFlow(self.cell.content) {
            imageFlow
        } else {
            InlineText(self.cell.content)
        }
    }
}
