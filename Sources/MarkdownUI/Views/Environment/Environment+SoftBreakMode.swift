import SwiftUI

public extension View {
    /// Sets the soft break mode for inline texts in a view hierarchy.
    ///
    /// - parameter softBreakMode: If set to `space`, treats all soft breaks as spaces, keeping sentences whole. If set to `lineBreak`, treats soft breaks as full line breaks
    ///
    /// - Returns: A view that uses the specified soft break mode for itself and its child views.
    func markdownSoftBreakMode(_ softBreakMode: SoftBreak.Mode) -> some View {
        self.environment(\.softBreakMode, softBreakMode)
    }
}

extension EnvironmentValues {
    @Entry var softBreakMode: SoftBreak.Mode = .space
}
