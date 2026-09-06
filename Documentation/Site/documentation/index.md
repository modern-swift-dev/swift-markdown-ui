---
title: "Documentation | MarkdownUI"
description: "MarkdownUI documentation for SwiftUI projects."
---

Documentation

# Build Markdown views with SwiftUI.

MarkdownUI supports headings, lists, task lists, blockquotes, code blocks, tables, thematic breaks, images, links, and styled text from GitHub Flavored Markdown.

[Getting started](/docs/swift-markdown-ui/documentation/getting-started/) — Create a MarkdownView and apply a theme.

[MarkdownUI API](/docs/swift-markdown-ui/documentation/markdownui/) — Open the hosted DocC reference for the renderer.

[MarkdownUIEditor](/docs/swift-markdown-ui/documentation/markdownuieditor/) — Add native editing with document bindings, formatting controls, themes, and image providers.

## Edit Markdown in your app

Link the `MarkdownUIEditor` package product to your app target, then bind Markdown source or a typed `MarkdownDocument` to the editor. Native editing supports iOS 17+, macOS 15+, and Mac Catalyst 17+.

```swift
import MarkdownUIEditor
import SwiftUI

struct NotesEditor: View {
  @State private var markdown = "# Notes"

  var body: some View {
    MarkdownEditor(markdown: $markdown)
      .markdownEditorTheme(.gitHub)
  }
}
```

The binding receives normalized Markdown after edits. The editor includes formatting controls; configure an image provider with `markdownEditorImageProvider(_:)` to load images.

The [editor's DocC guides and API reference](/docs/swift-markdown-ui/documentation/markdownuieditor/) cover native Markdown editing for SwiftUI, UIKit, and AppKit.

You can also [open the published MarkdownUI DocC documentation on Swift Package Index](https://swiftpackageindex.com/modern-swift-dev/swift-markdown-ui/main/documentation/markdownui).
