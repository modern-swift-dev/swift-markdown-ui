import SwiftUI

/// Controls when a Markdown view creates its block views.
public enum MarkdownBlockRenderingMode: Sendable {
    /// Measures all blocks immediately. This is the default.
    case eager
    /// Creates blocks as they approach the visible region of a scroll view.
    ///
    /// Nested content within each block remains eager. As with other lazy stacks, offscreen
    /// geometry is estimated; image loading and newly measured margins can adjust scroll position.
    case lazy
    /// Creates top-level blocks, list items, nested blockquote/list content, and
    /// table rows with explicit column widths as they approach the visible region
    /// of a scroll view. Set matching widths using `markdownTableColumnWidths(_:)`;
    /// tables without matching widths retain their content-sized, eager layout.
    /// Table row laziness also requires standard solid borders with whole-point
    /// widths; custom strokes and fractional border widths remain eager.
    ///
    /// Offscreen geometry is estimated. Newly measured margins, image sizes, and
    /// numbered-list marker widths can adjust layout and scroll position.
    case lazyContainers

    var nestedRenderingMode: Self {
        switch self {
            case .lazyContainers:
                .lazy
            case .eager,
                 .lazy:
                .eager
        }
    }
}

public extension View {
    /// Enables lazy rendering for large Markdown documents inside a scroll view.
    ///
    /// The default is `.eager`. Use `.lazy` when limiting initially created views is more
    /// important than having exact geometry for blocks that have not appeared yet.
    /// Use `.lazyContainers` to also defer list items, nested blockquote/list content,
    /// and table rows when `markdownTableColumnWidths(_:)` supplies matching widths.
    func markdownBlockRenderingMode(_ mode: MarkdownBlockRenderingMode) -> some View {
        self.environment(\.markdownBlockRenderingMode, mode)
    }
}

extension EnvironmentValues {
    @Entry var markdownBlockRenderingMode: MarkdownBlockRenderingMode = .eager
}
