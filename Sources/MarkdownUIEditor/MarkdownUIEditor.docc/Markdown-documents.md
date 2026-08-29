# Markdown documents

`MarkdownDocument` owns the persistent, structured form of an editor document. Create one from Markdown source, or construct it from blocks when your application already has a structured value.

```swift
import MarkdownUIEditor

var document = MarkdownDocument(markdown: "# Shopping\n\n- [ ] Milk")
document.blocks.append(.paragraph([.text("Pick up coffee too.")]))

let normalizedMarkdown = document.markdown
```

`markdown` serializes the current AST. It preserves document meaning and supported metadata such as link and image titles, list structure, table alignment, raw HTML, and code-fence information. It does not preserve the exact imported delimiters or whitespace.

For example, applications that also use the separate renderer can exchange a string at their boundary:

```swift
import MarkdownUI
import MarkdownUIEditor

let document = MarkdownDocument(markdown: "**Draft**")
let rendered = MarkdownView(document.markdown)
```

Do not store selection, marked text, or typing attributes in `MarkdownDocument`. Those belong to the live editor. The editor has no uncommitted Markdown source draft.
