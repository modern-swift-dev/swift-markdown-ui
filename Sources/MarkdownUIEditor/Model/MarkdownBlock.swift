import Foundation

/// A block-level construct in a Markdown document.
public enum MarkdownBlock: Hashable, Sendable {
    /// A block quote containing nested blocks.
    case blockquote([MarkdownBlock])
    /// An ordered, unordered, or task list.
    case list(MarkdownList)
    /// A fenced or indented code block, with an optional info string.
    case codeBlock(info: String?, content: String)
    /// A block of HTML preserved verbatim.
    case html(String)
    /// A paragraph containing inline content.
    case paragraph([MarkdownInline])
    /// A heading with a level and inline content.
    case heading(level: MarkdownHeadingLevel, content: [MarkdownInline])
    /// A GitHub Flavored Markdown table.
    case table(MarkdownTable)
    /// A horizontal rule.
    case thematicBreak
}

/// The six heading levels supported by Markdown.
public enum MarkdownHeadingLevel: Int, CaseIterable, Hashable, Sendable {
    /// A level-one heading.
    case one = 1
    /// A level-two heading.
    case two
    /// A level-three heading.
    case three
    /// A level-four heading.
    case four
    /// A level-five heading.
    case five
    /// A level-six heading.
    case six
}

/// The content and layout metadata for a Markdown list.
public struct MarkdownList: Hashable, Sendable {
    /// Whether items use bullets or ordinal markers.
    public var kind: MarkdownListKind
    /// Whether adjacent list items omit blank lines.
    public var isTight: Bool
    /// The list items in source order.
    public var items: [MarkdownListItem]

    /// Creates a list with the given layout and items.
    public init(kind: MarkdownListKind, isTight: Bool, items: [MarkdownListItem]) {
        self.kind = kind
        self.isTight = isTight
        self.items = items
    }
}

/// The marker style used by a Markdown list.
public enum MarkdownListKind: Hashable, Sendable {
    /// A list marked with bullets.
    case unordered
    /// A list numbered from the supplied value.
    case ordered(start: Int)
}

/// A single item in a Markdown list.
public struct MarkdownListItem: Hashable, Sendable {
    /// The item's checkbox state, or `nil` when it is not a task item.
    public var taskState: MarkdownTaskState?
    /// The blocks nested beneath this list marker.
    public var blocks: [MarkdownBlock]

    /// Creates a list item with optional task state.
    public init(taskState: MarkdownTaskState? = nil, blocks: [MarkdownBlock]) {
        self.taskState = taskState
        self.blocks = blocks
    }
}

/// The checked state of a task-list item.
public enum MarkdownTaskState: Hashable, Sendable {
    /// The task is incomplete.
    case unchecked
    /// The task is complete.
    case checked
}
