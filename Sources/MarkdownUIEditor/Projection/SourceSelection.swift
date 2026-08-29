/// A cursor boundary in Markdown source, with a preference at ambiguous mappings.
struct SourceAnchor: Hashable, Sendable {
    /// Chooses which side of hidden markup owns an ambiguous boundary.
    enum Affinity: Hashable, Sendable {
        /// Prefer the segment before the boundary.
        case upstream
        /// Prefer the segment after the boundary.
        case downstream
    }

    /// UTF-16 offset in serialized Markdown source.
    var utf16Offset: Int
    /// Preference used when mapping this offset into projected text.
    var affinity: Affinity

    init(utf16Offset: Int, affinity: Affinity = .downstream) {
        self.utf16Offset = utf16Offset
        self.affinity = affinity
    }
}

/// A source-backed selection that survives projection rebuilds.
struct EditorSelection: Hashable, Sendable {
    /// Fixed end of the selection.
    var anchor: SourceAnchor
    /// Moving end of the selection.
    var head: SourceAnchor

    init(anchor: SourceAnchor, head: SourceAnchor) {
        self.anchor = anchor
        self.head = head
    }

    init(caret: SourceAnchor) {
        self.init(anchor: caret, head: caret)
    }

    var isCollapsed: Bool {
        anchor.utf16Offset == head.utf16Offset
    }
}
