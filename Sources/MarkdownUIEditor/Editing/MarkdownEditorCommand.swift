import Foundation

extension MarkdownEditorCommand {
    static let contextualInlineCommands: [(title: String, command: Self)] = [
        ("Bold", .toggleInline(.strong)),
        ("Italic", .toggleInline(.emphasis)),
        ("Strikethrough", .toggleInline(.strikethrough))
    ]
}

/// An inline style that an editor command can toggle.
public enum MarkdownInlineStyle: Hashable, Sendable {
    /// Emphasized text.
    case emphasis
    /// Strong text.
    case strong
    /// Struck-through text.
    case strikethrough
    /// Inline code.
    case code
}

/// A block style that an editor command can apply to the active block.
public enum MarkdownBlockStyle: Hashable, Sendable {
    /// A paragraph.
    case paragraph
    /// A heading at the supplied level.
    case heading(MarkdownHeadingLevel)
    /// A block quote.
    case blockquote
    /// A code block with an optional info string.
    case code(info: String?)
}

/// A list style that an editor command can apply to selected blocks.
public enum MarkdownListStyle: Hashable, Sendable {
    /// A bulleted list.
    case unordered
    /// A numbered list beginning at the supplied value.
    case ordered(start: Int)
    /// A task list with unchecked items.
    case task
}

/// A direction used when moving a row or column.
public enum MarkdownMoveDirection: Hashable, Sendable {
    /// Move toward the preceding item.
    case backward
    /// Move toward the following item.
    case forward
}

/// A logical edit that can be applied to a `MarkdownDocument` as one undo unit.
public enum MarkdownEditorCommand: Hashable, Sendable {
    /// Applies or removes an inline style at the selection.
    case toggleInline(MarkdownInlineStyle)
    /// Converts the active block to a new block style.
    case convertBlock(MarkdownBlockStyle)
    /// Wraps selected blocks in a list or changes their list style.
    case convertList(MarkdownListStyle)
    /// Toggles the active task-list item's checkbox.
    case toggleTask
    /// Nests the current list item one level deeper.
    case indent
    /// Moves the current list item one level outward.
    case outdent
    /// Adds or updates a link for the selection.
    case setLink(destination: String, title: String?)
    /// Removes a link while preserving its child content.
    case removeLink
    /// Inserts an image reference at the selection.
    case insertImage(source: String, title: String?, alt: String)
    /// Replaces the active block with a horizontal rule.
    case insertThematicBreak
    /// Inserts a table with the requested columns and body rows.
    case insertTable(columns: Int, bodyRows: Int)
    /// Inserts a row near the active table cell.
    case insertTableRow
    /// Deletes the active table row.
    case deleteTableRow
    /// Moves the active table row.
    case moveTableRow(MarkdownMoveDirection)
    /// Inserts a column near the active table cell.
    case insertTableColumn
    /// Deletes the active table column.
    case deleteTableColumn
    /// Moves the active table column.
    case moveTableColumn(MarkdownMoveDirection)
    /// Changes the alignment of the active table column.
    case setTableColumnAlignment(MarkdownTableAlignment)
}
