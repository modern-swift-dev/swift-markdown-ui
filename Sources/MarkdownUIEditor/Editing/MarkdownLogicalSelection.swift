import Foundation

/// A document-model address used by structural editing commands.
indirect enum MarkdownLogicalPath: Hashable, Sendable {
    /// A top-level block.
    case block(Int)
    /// A block nested in a block quote.
    case blockquote(parent: MarkdownLogicalPath, child: Int)
    /// A block nested in a list item.
    case listItemBlock(list: MarkdownLogicalPath, item: Int, block: Int)
    /// Row zero is the header. Body rows start at one.
    case tableCell(table: MarkdownLogicalPath, row: Int, column: Int)
}

/// A selection expressed against a logical text-bearing node.
struct MarkdownLogicalSelection: Hashable, Sendable {
    /// The text-bearing block or table cell containing the selection.
    var path: MarkdownLogicalPath
    /// Selection start in the node's UTF-16 text.
    var utf16Offset: Int
    /// Selection length in UTF-16 code units.
    var utf16Length: Int

    init(path: MarkdownLogicalPath, utf16Offset: Int = 0, utf16Length: Int = 0) {
        self.path = path
        self.utf16Offset = utf16Offset
        self.utf16Length = utf16Length
    }
}

/// The document and selection produced by one structural command.
struct MarkdownEditingResult: Hashable, Sendable {
    /// Document after the command.
    var document: MarkdownDocument
    /// Selection to restore after reprojecting the document.
    var selection: MarkdownLogicalSelection
}
