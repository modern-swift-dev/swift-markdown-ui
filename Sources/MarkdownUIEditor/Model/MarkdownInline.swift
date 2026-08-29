import Foundation

/// An inline construct within a paragraph, heading, or table cell.
public enum MarkdownInline: Hashable, Sendable {
    /// Plain text.
    case text(String)
    /// A source newline that may wrap as a space.
    case softBreak
    /// A forced line break.
    case lineBreak
    /// Inline code, without its Markdown delimiters.
    case code(String)
    /// Inline HTML preserved verbatim.
    case html(String)
    /// Content emphasized with Markdown markers.
    case emphasis([MarkdownInline])
    /// Content made strong with Markdown markers.
    case strong([MarkdownInline])
    /// Content marked as deleted.
    case strikethrough([MarkdownInline])
    /// Linked content, with a destination and optional title.
    case link(destination: String, title: String?, children: [MarkdownInline])
    /// An image reference, with alt text stored in `children`.
    case image(source: String, title: String?, children: [MarkdownInline])
}
