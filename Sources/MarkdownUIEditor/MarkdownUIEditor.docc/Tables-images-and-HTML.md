# Tables, images, and HTML

Tables are represented by ``MarkdownTable`` and displayed as native TextKit attachments. Cells display editable rich text with the same inline GFM formatting as the document. Formatting commands use the visible cell selection. Return inserts a visible newline and stores it as `<br />`. `Tab` moves forward, `Shift-Tab` moves backward, and reaching the final cell adds a row. Column alignment follows the table model, and the grid grows and wraps within the editor width as cells change. A table remains one structural document node.

Cell changes flow through the table controller to the enclosing editor's document and undo history. Hosts can still use the controller's source API to read or replace a cell as Markdown.

Right-click a cell on macOS, or open a cell's text-editing menu on iOS, and choose **Table** to add, delete, or move rows and columns and change column alignment. Commands target that cell and participate in the editor's undo history. Unavailable operations, such as deleting the header row, are disabled. These contextual controls are available even when the formatting toolbar is hidden.

Use ``MarkdownTableController`` when a host needs direct table operations outside the text view.

```swift
import MarkdownUIEditor

var table = MarkdownTable(
    alignments: [.left, .right],
    header: MarkdownTableRow(cells: [
        MarkdownTableCell(content: [.text("Item")]),
        MarkdownTableCell(content: [.text("Count")])
    ]),
    rows: []
)

let controller = MarkdownTableController(table: table)
controller.appendRow()
table = controller.table
```

Images keep their Markdown URL, title, and alt text in ``MarkdownImageMetadata``. An optional ``MarkdownEditorImageProvider`` resolves a URL to a platform image for display. The editor does not upload, store, or generate image assets.

Image loading is opt-in. In SwiftUI, keep a provider in your view or model and set
it with `markdownEditorImageProvider(_:)`. Relative image paths resolve against
the editor's `baseURL`. Without a provider, the image attachment displays its
alternative text.

```swift
import MarkdownUIEditor
import SwiftUI

struct IllustratedNotes: View {
    @State private var markdown = "![Diagram](images/diagram.png)"
    @State private var imageProvider = MarkdownURLSessionImageProvider()

    var body: some View {
        MarkdownEditor(
            markdown: $markdown,
            baseURL: URL(string: "https://example.com/notes/")
        )
        .markdownEditorImageProvider(imageProvider)
    }
}
```

Implement ``MarkdownEditorImageProvider`` for local assets, caching, or custom
networking. For native TextKit integration, pass a provider to the attachment:

```swift
import MarkdownUIEditor

let provider = MarkdownURLSessionImageProvider()
let metadata = MarkdownImageMetadata(source: "https://example.com/image.png", altText: "Example")
let attachment = MarkdownImageAttachment(metadata: metadata, imageProvider: provider)
```

`MarkdownBlock.html` and `MarkdownInline.html` preserve raw HTML as source. HTML is never executed or previewed.
