import SwiftUI

/// Controls when a Markdown view creates its top-level block views.
public enum MarkdownBlockRenderingMode: Sendable {
    /// Measures all blocks immediately. This is the default.
    case eager
    /// Creates blocks as they approach the visible region of a scroll view.
    ///
    /// Nested content within each block remains eager. As with other lazy stacks, offscreen
    /// geometry is estimated; image loading and newly measured margins can adjust scroll position.
    case lazy
}

public extension View {
    /// Enables lazy top-level rendering for large Markdown documents inside a scroll view.
    ///
    /// The default is `.eager`. Use `.lazy` when limiting initially created views is more
    /// important than having exact geometry for blocks that have not appeared yet.
    func markdownBlockRenderingMode(_ mode: MarkdownBlockRenderingMode) -> some View {
        self.environment(\.markdownBlockRenderingMode, mode)
    }
}

extension EnvironmentValues {
    @Entry var markdownBlockRenderingMode: MarkdownBlockRenderingMode = .eager
}
