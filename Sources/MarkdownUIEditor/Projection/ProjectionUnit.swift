/// A replaceable leaf of the document projection.
struct ProjectionUnit: Hashable, Sendable {
    /// The block type represented by the unit.
    enum Kind: Hashable, Sendable {
        case paragraph
        case heading(MarkdownHeadingLevel)
        case codeBlock
        case htmlBlock
        case table
        case thematicBreak
    }

    /// Projection-local identity stored in native attributes.
    var id: EditorNodeID
    /// Stable structural address in the Markdown document.
    var path: EditorNodePath
    /// The rendered block type.
    var kind: Kind
    /// Complete projected range for this leaf, including its terminating newline.
    var projectionRange: ProjectionUTF16Range
    /// Complete serialized source range for this leaf.
    var sourceRange: SourceUTF16Range
    /// Fine-grained visible and hidden mappings inside the unit.
    var segments: [OffsetMapSegment]
}
