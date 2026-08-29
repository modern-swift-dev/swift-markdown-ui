import Foundation

/// A type-safe representation of a GitHub Flavored Markdown document.
public struct MarkdownDocument: Hashable, Sendable {
    /// The document's top-level blocks, in source order.
    public var blocks: [MarkdownBlock]

    /// Creates a document from its top-level blocks.
    public init(blocks: [MarkdownBlock] = []) {
        self.blocks = blocks
    }
}
