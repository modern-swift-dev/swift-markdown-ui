# SwiftUI editor

Use a document binding when the app needs structured Markdown. Use a string binding when it stores Markdown source.

```swift
import MarkdownUIEditor
import SwiftUI

struct DocumentEditor: View {
    @State private var document = MarkdownDocument(markdown: "# Draft")

    var body: some View {
        MarkdownEditor(document: $document)
            .markdownEditorTheme(.gitHub)
    }
}
```

The string initializer parses the binding value on input and writes normalized Markdown after an edit.

Assign a new value to the binding to replace the document, such as when opening
another note or restoring a saved version. Use a document binding when you also
need to retain empty paragraphs during editing; Markdown source normalizes them.

```swift
import MarkdownUIEditor
import SwiftUI

struct SourceEditor: View {
    @State private var markdown = "A [relative link](guide.md)"

    var body: some View {
        MarkdownEditor(markdown: $markdown, baseURL: URL(string: "https://example.com/docs/")!)
            .markdownEditorShowsFormattingToolbar(false)
    }
}
```

`baseURL` resolves relative image URLs in the editor projection. It does not rewrite the Markdown document.

`MarkdownEditorTheme` belongs to this product. It is not `MarkdownUI.Theme` and does not require the renderer. Choose `.basic`, `.gitHub`, or `.docC`, or initialize a theme with native attributed-string attributes.

The default toolbar includes bold, italic, strikethrough, inline code, paragraph styles, lists, links, images, and table commands. Its enabled and selected states follow the current selection. Commands return keyboard focus to the edited text or table cell so typing can continue after using a control.
