/// One contiguous relationship between projected text and Markdown source.
struct OffsetMapSegment: Hashable, Sendable {
    /// How this segment appears in the native projection.
    enum Kind: Hashable, Sendable {
        /// Source and projection both expose text.
        case text
        /// Markdown syntax omitted from the native projection.
        case hiddenSource
        /// A native attachment that represents a source object.
        case objectReplacement
    }

    /// Range in the native projection.
    var projectionRange: ProjectionUTF16Range
    /// Corresponding range in Markdown source.
    var sourceRange: SourceUTF16Range
    /// Whether the segment is visible text, hidden syntax, or an attachment.
    var kind: Kind
}
