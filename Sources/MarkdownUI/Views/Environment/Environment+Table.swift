import SwiftUI

public extension View {
    /// Sets the table border style for the Markdown tables in a view hierarchy.
    ///
    /// Use this modifier to customize the table border style inside the body of
    /// the ``Theme/table`` block style.
    ///
    /// - Parameter tableBorderStyle: The border style to set.
    func markdownTableBorderStyle(_ tableBorderStyle: TableBorderStyle) -> some View {
        self.environment(\.tableBorderStyle, tableBorderStyle)
    }

    /// Sets the table background style for the Markdown tables in a view hierarchy.
    ///
    /// Use this modifier to customize the table background style inside the body of
    /// the ``Theme/table`` block style.
    ///
    /// - Parameter tableBackgroundStyle: The background style to set.
    func markdownTableBackgroundStyle(
        _ tableBackgroundStyle: TableBackgroundStyle
    ) -> some View {
        self.environment(\.tableBackgroundStyle, tableBackgroundStyle)
    }
}

extension EnvironmentValues {
    @Entry var tableBorderStyle: TableBorderStyle = .init(color: .secondary)

    @Entry var tableBackgroundStyle: TableBackgroundStyle = .clear
}
