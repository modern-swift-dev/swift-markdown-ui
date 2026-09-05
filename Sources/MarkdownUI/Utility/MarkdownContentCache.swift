/// Keeps only the last parsed source for one mounted Markdown view.
///
/// This deliberately does not participate in observation: memoizing a synchronous
/// parse during body evaluation must not schedule another view update.
@MainActor final class MarkdownContentCache {
    private var last: (source: String, content: MarkdownContent)?
    private let parse: (String) -> MarkdownContent

    init(parse: @escaping (String) -> MarkdownContent = { MarkdownContent($0) }) {
        self.parse = parse
    }

    func content(for source: String) -> MarkdownContent {
        if let last = self.last, last.source == source {
            return last.content
        }
        // Drop the previous document before parsing its replacement.
        self.last = nil
        let content = self.parse(source)
        self.last = (source, content)
        return content
    }

    func clear() {
        self.last = nil
    }
}
