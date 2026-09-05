# Content behavior

Paragraphs, headings, quotes, list items, task items, code blocks, links, tables, images, and thematic breaks stay richly projected while the editor has focus. Moving the insertion point into strong text does not reveal `**` delimiters. Typing there inherits the strong semantic attribute and updates the matching inline node.

The native attributed text carries internal semantic attributes for strong, emphasis, strikethrough, inline code, and links. TextKit edits reconcile those attributes into localized ``MarkdownInline`` changes. The editor does not keep a Markdown source draft or parse source after each keystroke. IME marked text remains under TextKit's control until composition ends.

Ordinary typing reconciles only the affected projection unit. The editor reuses live text storage and shifts later projection ranges. Unrelated table and image attachments keep their identity. Return, deletion across a block boundary, structural commands, theme changes, external document replacement, and undo restoration may rebuild the full projection.

The editor uses the native undo manager. Typing, commands, table changes, paste, and structural deletion participate in native undo and redo.

Clipboard content carries Markdown and plain text. The editor prefers Markdown when structured Markdown content is available. Pasting bitmap data does not create managed image assets.

## Normalization

Markdown cannot store arbitrary font families, sizes, colors, underline, paragraph alignment, page layout, comments, or tracked changes. The editor drops those distinctions when it turns native text into ``MarkdownDocument`` and reapplies its theme from Markdown semantics.

Inline code and HTML retain their enclosing links and inline styles. Overlapping
runs use a stable nesting order: link, strong, emphasis, then strikethrough, around
the text, code, or HTML content. Adjacent equivalent wrappers merge. Markdown does
not permit nested links, so a link command keeps the visible children under one
link destination.

When punctuation would prevent a formatting delimiter from opening or closing,
serialization uses numeric character references for adjacent text. This preserves
the visible characters and formatting when the exported Markdown is parsed again.

Plain-text paste inserts literal text. Asterisks and brackets in that payload remain visible characters. Markdown paste parses through ``MarkdownDocument/init(markdown:)`` and inserts the resulting semantic content. Serialization always goes through ``MarkdownDocument/markdown``.
