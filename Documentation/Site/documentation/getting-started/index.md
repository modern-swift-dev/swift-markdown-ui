---
title: "Getting started | MarkdownUI"
description: "Create and style MarkdownUI views in SwiftUI."
---

Getting started

# Create a Markdown view.

Pass Markdown text to `MarkdownView`. The view renders GitHub Flavored Markdown with SwiftUI.

## Requirements

MarkdownUI requires macOS 15.0, iOS 17.0, tvOS 17.0, Mac Catalyst 17.0, watchOS 10.0, or visionOS 2.0 and later.

## Install with Swift Package Manager

Add MarkdownUI to your package dependencies, then add `MarkdownUI` to the target that imports it. This page uses the current stable release.

```swift
dependencies: [
  .package(
    url: "https://github.com/modern-swift-dev/swift-markdown-ui",
    from: "{{version}}"
  )
]
```

## Render your first string

The string initializer is the shortest path.

```swift
import SwiftUI
import MarkdownUI

struct ArticleView: View {
  let article: String

  var body: some View {
    MarkdownView(article)
  }
}
```

## Pre-parse content you keep

Create `MarkdownContent` in a model layer when you reuse the same source. It parses the Markdown before the view renders it.

```swift
import SwiftUI
import MarkdownUI

let content = MarkdownContent("## Release notes\n\nA parsed value.")

struct NotesView: View {
  var body: some View {
    MarkdownView(content)
  }
}
```

## Style the result

MarkdownUI uses its basic theme by default. Apply `.gitHub` to a Markdown view or an enclosing view hierarchy. Use `markdownTextStyle` and `markdownBlockStyle` when only one style needs to change.

```swift
MarkdownView("Use `git status` to list modified files.")
  .markdownTheme(.gitHub)
```

## Resolve links and images

`baseURL` resolves relative Markdown links. `imageBaseURL` resolves relative image URLs and otherwise uses `baseURL`. Configure a built-in or custom image provider with `markdownImageProvider`. Markdown links use SwiftUI's `openURL` environment action, which you can replace for custom handling.

```swift
import SwiftUI
import MarkdownUI

MarkdownView(
  "[Guide](guide) ![Diagram](images/diagram.png)",
  baseURL: URL(string: "https://example.com/docs/")!,
  imageBaseURL: URL(string: "https://cdn.example.com/")!
)
.markdownImageProvider(.default)
```

[Open the generated MarkdownUI DocC reference](/docs/swift-markdown-ui/documentation/markdownui/).
