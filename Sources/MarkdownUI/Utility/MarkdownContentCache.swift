/// Keeps only the last parsed source for one mounted Markdown view.
///
/// This deliberately does not participate in observation: memoizing a synchronous
/// parse during body evaluation must not schedule another view update.
@MainActor final class MarkdownContentCache {
    private var last: (source: String, content: MarkdownContent)?
    private var incrementalParser = IncrementalMarkdownParser()
    private let parse: ((String) -> MarkdownContent)?

    /// Creates a cache that reparses only the changed tail of a growing source.
    init() {
        self.parse = nil
    }

    /// Creates a cache that parses every changed source with `parse`.
    init(parse: @escaping (String) -> MarkdownContent) {
        self.parse = parse
    }

    func content(for source: String) -> MarkdownContent {
        if let last = self.last, last.source == source {
            return last.content
        }
        // Drop the previous document before parsing its replacement. The incremental
        // parser keeps what it needs to reuse the unchanged leading blocks.
        self.last = nil
        let content = self.parse?(source) ?? self.incrementalParser.parse(source)
        self.last = (source, content)
        return content
    }

    func clear() {
        self.last = nil
        self.incrementalParser = .init()
    }
}
