/// A link's destination and title, as the link dialog shows and edits them.
struct MarkdownEditorLink: Equatable {
    var destination: String
    var title: String?

    /// Sets the link at the selection. An empty title means the link has no title.
    var command: MarkdownEditorCommand {
        .setLink(destination: destination, title: title?.isEmpty == false ? title : nil)
    }
}
