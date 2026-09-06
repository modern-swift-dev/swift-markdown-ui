---
title: "Examples | MarkdownUI"
description: "Examples of MarkdownUI in SwiftUI."
---

Examples

# Strings when they fit. A builder when they do not.

MarkdownUI accepts ordinary Markdown strings and a Swift result builder. Both forms produce native SwiftUI views.

## Compose with the content builder

Use `Heading`, `Paragraph`, and list types where the content belongs in code.

```swift
import SwiftUI
import MarkdownUI

struct ReleaseNotesView: View {
  var body: some View {
    MarkdownView {
      Heading(.level2) { "Release notes" }
      Paragraph {
        Strong("MarkdownUI")
        " renders Markdown in SwiftUI."
      }
      TaskList {
        TaskListItem(isCompleted: true) { "Parse Markdown" }
        TaskListItem { "Apply a theme" }
      }
    }
  }
}
```

## Override one block style

Keep the active theme and replace just the blockquote presentation.

```swift
import SwiftUI
import MarkdownUI

MarkdownView("> A quote with custom presentation.")
  .markdownBlockStyle(\.blockquote) { configuration in
    configuration.label
      .padding()
      .overlay(alignment: .leading) {
        Rectangle().fill(.teal).frame(width: 4)
      }
  }
```
