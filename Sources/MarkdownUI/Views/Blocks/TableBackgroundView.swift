import SwiftUI

struct TableBackgroundView: View {
    @Environment(\.tableBackgroundStyle) private var tableBackgroundStyle

    private let tableBounds: TableBounds

    init(tableBounds: TableBounds) {
        self.tableBounds = tableBounds
    }

    var body: some View {
        if case let .custom(background) = self.tableBackgroundStyle.background {
            ZStack(alignment: .topLeading) {
                ForEach(0 ..< self.tableBounds.rowCount, id: \.self) { row in
                    ForEach(0 ..< self.tableBounds.columnCount, id: \.self) { column in
                        let bounds = self.tableBounds.bounds(forRow: row, column: column)

                        Rectangle()
                            .fill(background(row, column))
                            .offset(x: bounds.minX, y: bounds.minY)
                            .frame(width: bounds.width, height: bounds.height)
                    }
                }
            }
        } else {
            // Keep a concrete view so tableDecoration can publish its resolved bounds
            // preference for border rendering, even without cell backgrounds.
            Color.clear
        }
    }
}
