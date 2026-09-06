---
title: "MarkdownUI | Markdown for SwiftUI"
description: "Display and customize GitHub Flavored Markdown text in SwiftUI."
---

Swift package

# Markdown that belongs in SwiftUI.

MarkdownUI parses GitHub Flavored Markdown and renders it with native SwiftUI views. Use the built-in themes, or tune text and block styles for your app.

[Get started](/docs/swift-markdown-ui/documentation/getting-started/)

[See examples](/docs/swift-markdown-ui/examples/)

## Latest stable release

{{version}}

Published {{releaseDate}}

Swift Package Manager: `from: "{{version}}"`

[Release notes]({{releaseURL}})

## Markdown in the view hierarchy

```swift
import SwiftUI
import MarkdownUI

struct NotesView: View {
  var body: some View {
    MarkdownView("""
      ## Ship notes
      MarkdownUI renders **GitHub Flavored Markdown** in SwiftUI.
      """)
  }
}
```

### Rendered result: Ship notes

MarkdownUI renders rich text with native SwiftUI views.

- Headings and links
- Task lists and tables
- Inline code and fenced blocks

> Apply a theme, then override only the styles you need.

What it renders

## The Markdown people put in real app content.

MarkdownUI handles headings, styled text, links, images, bullet and numbered lists, task lists, blockquotes, code blocks, tables, and thematic breaks.

Platform requirements

- macOS 15.0+
- iOS 17.0+, tvOS 17.0+, and Mac Catalyst 17.0+
- watchOS 10.0+ and visionOS 2.0+

How it is built

## A SwiftUI renderer with GitHub Flavored Markdown at its core.

MarkdownUI is maintained in the [modern-swift-dev/swift-markdown-ui repository](https://github.com/modern-swift-dev/swift-markdown-ui). The package targets the GitHub Flavored Markdown specification and depends on Swift CMark's `cmark-gfm` and `cmark-gfm-extensions` products for parsing.

Documentation

## Start with the pieces you will use.

[Getting started](/docs/swift-markdown-ui/documentation/getting-started/) — Create a MarkdownView from a string, a content builder, or pre-parsed MarkdownContent.

[API documentation](/docs/swift-markdown-ui/documentation/markdownui/) — Read the generated DocC documentation for MarkdownUI types and modifiers.

[Examples](/docs/swift-markdown-ui/examples/) — See MarkdownView, content builders, and theme changes in focused Swift snippets.

Ready to add it?

## Start with a MarkdownView, then make it yours.

[Read the guide](/docs/swift-markdown-ui/documentation/getting-started/)

[View the repository](https://github.com/modern-swift-dev/swift-markdown-ui)

MarkdownUI is an open-source Swift package.
