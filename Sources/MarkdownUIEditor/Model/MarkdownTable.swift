import Foundation

/// A GitHub Flavored Markdown table.
public struct MarkdownTable: Hashable, Sendable {
    /// Column alignments, in display order.
    public var alignments: [MarkdownTableAlignment]
    /// The header row.
    public var header: MarkdownTableRow
    /// The body rows beneath the header.
    public var rows: [MarkdownTableRow]

    /// Creates a table with its column alignment, header, and body rows.
    public init(
        alignments: [MarkdownTableAlignment],
        header: MarkdownTableRow,
        rows: [MarkdownTableRow]
    ) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
    }
}

/// The alignment marker for a Markdown table column.
public enum MarkdownTableAlignment: Character, Hashable, Sendable {
    /// No explicit alignment marker.
    case none = "\0"
    /// Left-aligned content.
    case left = "l"
    /// Centered content.
    case center = "c"
    /// Right-aligned content.
    case right = "r"
}

/// A row in a Markdown table.
public struct MarkdownTableRow: Hashable, Sendable {
    /// Cells in display order.
    public var cells: [MarkdownTableCell]

    /// Creates a row from its cells.
    public init(cells: [MarkdownTableCell]) {
        self.cells = cells
    }
}

/// A table cell containing inline Markdown.
public struct MarkdownTableCell: Hashable, Sendable {
    /// The cell's inline content.
    public var content: [MarkdownInline]

    /// Creates a cell from inline content.
    public init(content: [MarkdownInline]) {
        self.content = content
    }
}
