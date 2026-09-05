import SwiftUI

/// A type that selects the visible borders on a Markdown table.
///
/// You use a table border selector to select the visible borders when creating a ``TableBorderStyle``.
public struct TableBorderSelector: Sendable {
    struct Components: OptionSet, Sendable {
        let rawValue: Int

        static let outside = Self(rawValue: 1 << 0)
        static let insideHorizontal = Self(rawValue: 1 << 1)
        static let insideVertical = Self(rawValue: 1 << 2)
        static let outsideHorizontal = Self(rawValue: 1 << 3)
    }

    let components: Components?
    var rectangles: @Sendable (_ tableBounds: TableBounds, _ borderWidth: CGFloat) -> [CGRect]

    init(
        components: Components? = nil,
        rectangles: @escaping @Sendable (_ tableBounds: TableBounds, _ borderWidth: CGFloat) -> [CGRect]
    ) {
        self.components = components
        self.rectangles = rectangles
    }
}

public extension TableBorderSelector {
    /// A table border selector that selects the outside borders of a table.
    static var outsideBorders: TableBorderSelector {
        TableBorderSelector(components: [.outside]) { tableBounds, _ in
            [tableBounds.bounds]
        }
    }

    /// A table border selector that selects the inside borders of a table.
    static var insideBorders: TableBorderSelector {
        TableBorderSelector(components: [.insideHorizontal, .insideVertical]) { tableBounds, borderWidth in
            Self.insideHorizontalBorders.rectangles(tableBounds, borderWidth)
                + Self.insideVerticalBorders.rectangles(tableBounds, borderWidth)
        }
    }

    /// A table border selector that selects the inside horizontal borders of a table.
    static var insideHorizontalBorders: TableBorderSelector {
        TableBorderSelector(components: [.insideHorizontal]) { tableBounds, borderWidth in
            (0 ..< tableBounds.rowCount - 1)
                .map {
                    tableBounds.bounds(forRow: $0)
                        .insetBy(dx: -borderWidth, dy: -borderWidth)
                }
                .map {
                    CGRect(
                        origin: .init(x: $0.minX, y: $0.maxY - borderWidth),
                        size: .init(width: $0.width, height: borderWidth)
                    )
                }
        }
    }

    /// A table border selector that selects the inside vertical borders of a table.
    static var insideVerticalBorders: TableBorderSelector {
        TableBorderSelector(components: [.insideVertical]) { tableBounds, borderWidth in
            (0 ..< tableBounds.columnCount - 1)
                .map {
                    tableBounds.bounds(forColumn: $0)
                        .insetBy(dx: -borderWidth, dy: -borderWidth)
                }
                .map {
                    CGRect(
                        origin: .init(x: $0.maxX - borderWidth, y: $0.minY),
                        size: .init(width: borderWidth, height: $0.height)
                    )
                }
        }
    }

    /// A table border selector that selects the horizontal borders of a table.
    static var horizontalBorders: TableBorderSelector {
        TableBorderSelector(components: [.outsideHorizontal, .insideHorizontal]) { tableBounds, borderWidth in
            Self.outsideHorizontalBorders.rectangles(tableBounds, borderWidth)
                + Self.insideHorizontalBorders.rectangles(tableBounds, borderWidth)
        }
    }

    /// A table border selector that selects all the borders of a table.
    static var allBorders: TableBorderSelector {
        TableBorderSelector(components: [.insideHorizontal, .insideVertical, .outside]) { tableBounds, borderWidth in
            Self.insideBorders.rectangles(tableBounds, borderWidth)
                + Self.outsideBorders.rectangles(tableBounds, borderWidth)
        }
    }
}

private extension TableBorderSelector {
    static var outsideHorizontalBorders: TableBorderSelector {
        TableBorderSelector(components: [.outsideHorizontal]) { tableBounds, borderWidth in
            [
                CGRect(
                    origin: .init(x: tableBounds.bounds.minX, y: tableBounds.bounds.minY),
                    size: .init(width: tableBounds.bounds.width, height: borderWidth)
                ),
                CGRect(
                    origin: .init(x: tableBounds.bounds.minX, y: tableBounds.bounds.maxY - borderWidth),
                    size: .init(width: tableBounds.bounds.width, height: borderWidth)
                )
            ]
        }
    }
}
