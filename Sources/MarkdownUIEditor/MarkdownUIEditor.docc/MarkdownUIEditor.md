# ``MarkdownUIEditor``

Create and edit GitHub Flavored Markdown with native text controls on iOS, Mac Catalyst, and macOS.

`MarkdownUIEditor` is a separate library product from `MarkdownUI`. It does not import the renderer and the renderer does not import the editor. Move content between them as Markdown source when an application uses both products.

Native editing supports iOS 17.0+, macOS 15.0+, and Mac Catalyst 17.0+.

## Installation

Add the `swift-markdown-ui` package to your project and link its
`MarkdownUIEditor` product to the target that uses the editor. In a Swift package,
add this entry to your target's dependencies:

```swift
.product(name: "MarkdownUIEditor", package: "swift-markdown-ui")
```

In Xcode, add `MarkdownUIEditor` under your app target's **Frameworks,
Libraries, and Embedded Content**. Import `MarkdownUIEditor` in your source files.

```swift
import MarkdownUI
import MarkdownUIEditor

let document = MarkdownDocument(markdown: "# Notes")
let source = document.markdown
let view = MarkdownView(source)
```

## Topics

### Getting started

- ``MarkdownEditor``
- ``MarkdownDocument``
- <doc:Markdown-documents>
- <doc:SwiftUI-editor>
- <doc:Native-text-views>

### Editing

- <doc:Commands-and-focus>
- <doc:Content-behavior>
- <doc:Platform-behavior>

### Supporting content

- <doc:Tables-images-and-HTML>
- ``MarkdownEditorTheme``
- ``MarkdownEditorImageProvider``

## Overview

The editor parses GitHub Flavored Markdown into ``MarkdownDocument``. The document is a value type containing type-safe ``MarkdownBlock`` and ``MarkdownInline`` values. Its ``MarkdownDocument/markdown`` property serializes that structure into normalized Markdown. Imported spelling and whitespace are not retained when the editor writes the document back.

`MarkdownEditor` is the SwiftUI entry point. ``MarkdownTextView`` is the native view for UIKit or AppKit hosts. Both use TextKit 2.

The editor keeps the TextKit 2 document rich while it has focus. Markdown delimiters do not become editable text when the insertion point enters a block. Native edits change the typed AST directly, and Markdown serialization happens only at a source boundary such as a string binding or clipboard export.

## Strict GFM scope

The parser uses cmark-gfm with autolinks, strikethrough, task lists, tables, and tag filtering enabled. It supports paragraphs, headings, block quotes, ordered and unordered lists, task lists, fenced code blocks, thematic breaks, tables, links, images, inline HTML, and block HTML.

The editor has one dialect: GitHub Flavored Markdown. It does not add footnotes or citation extensions. Raw HTML is source content. The editor neither executes it nor turns it into a live preview.
