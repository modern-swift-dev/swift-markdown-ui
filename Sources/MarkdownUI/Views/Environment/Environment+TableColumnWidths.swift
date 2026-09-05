import SwiftUI

public extension View {
    /// Sets explicit table column widths, including each cell's themed padding.
    ///
    /// A finite, positive width is required for every column. Invalid widths or a
    /// count that does not match a table preserve its content-sized, eager layout.
    /// With `.lazyContainers`, matching widths allow table rows to be created as
    /// they approach the visible region when borders use a standard solid stroke
    /// with a positive, whole-point line width. Custom strokes, dashed borders,
    /// and fractional border widths retain eager layout to preserve their exact
    /// appearance. Offscreen row heights remain estimated.
    /// Other rendering modes honor matching widths while measuring all rows.
    func markdownTableColumnWidths(_ widths: [CGFloat]) -> some View {
        let valid = !widths.isEmpty
            && widths.allSatisfy { $0.isFinite && $0 > 0 }
            && widths.reduce(0, +).isFinite
        return self.environment(\.tableColumnWidths, valid ? widths : nil)
    }
}

extension EnvironmentValues {
    @Entry var tableColumnWidths: [CGFloat]?
}
