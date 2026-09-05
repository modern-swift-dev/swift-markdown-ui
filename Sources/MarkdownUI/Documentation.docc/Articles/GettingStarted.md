# Getting started

Learn how to display and style Markdown text in SwiftUI.

## Creating a Markdown view

A `Markdown` view displays rich structured text using the Markdown syntax. It can display images,
headings, lists (including task lists), blockquotes, code blocks, tables, and thematic breaks,
besides styled text and links.

The simplest way of creating a `Markdown` view is to pass a Markdown string to the
``MarkdownView/init(_:baseURL:imageBaseURL:)-(String,_,_)`` initializer.

```swift
let markdownString = """
  ## Try MarkdownUI

  **MarkdownUI** is a native Markdown renderer for SwiftUI
  compatible with the
  [GitHub Flavored Markdown Spec](https://github.github.com/gfm/).
  """

var body: some View {
  MarkdownView(markdownString)
}
```

![](MarkdownString)

A more convenient way to create a `Markdown` view is by using the
``MarkdownView/init(baseURL:imageBaseURL:content:)`` initializer, which takes a Markdown content
builder in which you can compose the view content, either by providing Markdown strings or by
using an expressive domain-specific language.

```swift
var body: some View {
  MarkdownView {
    """
    ## Using a Markdown Content Builder
    Use Markdown strings or an expressive domain-specific language
    to build the content.
    """
    Heading(.level2) {
      "Try MarkdownUI"
    }
    Paragraph {
      Strong("MarkdownUI")
      " is a native Markdown renderer for SwiftUI"
      " compatible with the "
      InlineLink(
        "GitHub Flavored Markdown Spec",
        destination: URL(string: "https://github.github.com/gfm/")!
      )
      "."
    }
  }
}
```

![](MarkdownContentBuilder)

You can also create a ``MarkdownContent`` value in your model layer and later create a `Markdown`
view by passing the content value to the ``MarkdownView/init(_:baseURL:imageBaseURL:)-(MarkdownContent,_,_)``
initializer. The ``MarkdownContent`` value pre-parses the Markdown string preventing the view from
doing this step.

```swift
// Somewhere in the model layer
let content = MarkdownContent("You can try **CommonMark** [here](https://spec.commonmark.org/dingus/).")

// Later in the view layer
var body: some View {
  MarkdownView(self.model.content)
}
```

## Styling Markdown

Markdown views use a basic default theme to display the contents. For more information, read about
the ``Theme/basic`` theme.

```swift
MarkdownView {
  """
  You can quote text with a `>`.

  > Outside of a dog, a book is man's best friend. Inside of a
  > dog it's too dark to read.

  – Groucho Marx
  """
}
```

![](BlockquoteContent)

You can customize the appearance of Markdown content by applying different themes using the
`markdownTheme(_:)` modifier. For example, you can apply one of the built-in themes, like
``Theme/gitHub``, to either a Markdown view or a view hierarchy that contains Markdown views.

```swift
MarkdownView {
  """
  You can quote text with a `>`.

  > Outside of a dog, a book is man's best friend. Inside of a
  > dog it's too dark to read.

  – Groucho Marx
  """
}
.markdownTheme(.gitHub)
```

![](GitHubBlockquote)

To override a specific text style from the current theme, use the `markdownTextStyle(_:textStyle:)`
modifier. The following example shows how to override the ``Theme/code`` text style.

```swift
MarkdownView {
  """
  Use `git status` to list all new or modified files
  that haven't yet been committed.
  """
}
.markdownTextStyle(\.code) {
  FontFamilyVariant(.monospaced)
  FontSize(.em(0.85))
  ForegroundColor(.purple)
  BackgroundColor(.purple.opacity(0.25))
}
```

![](CustomInlineCode)

You can also use the `markdownBlockStyle(_:body:)` modifier to override a specific block style. For
example, you can override only the ``Theme/blockquote`` block style, leaving other block styles
untouched.

```swift
MarkdownView {
  """
  You can quote text with a `>`.

  > Outside of a dog, a book is man's best friend. Inside of a
  > dog it's too dark to read.

  – Groucho Marx
  """
}
.markdownBlockStyle(\.blockquote) { configuration in
  configuration.label
    .padding()
    .markdownTextStyle {
      FontCapsVariant(.lowercaseSmallCaps)
      FontWeight(.semibold)
      BackgroundColor(nil)
    }
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(Color.teal)
        .frame(width: 4)
    }
    .background(Color.teal.opacity(0.5))
}
```

![](CustomBlockquote)

Another way to customize the appearance of Markdown content is to create your own theme. To create
a theme, start by instantiating an empty ``Theme`` and chain together the different text and block
styles in a single expression.

```swift
extension Theme {
  static let fancy = Theme()
    .code {
      FontFamilyVariant(.monospaced)
      FontSize(.em(0.85))
    }
    .link {
      ForegroundColor(.purple)
    }
    // More text styles...
    .paragraph { configuration in
      configuration.label
        .relativeLineSpacing(.em(0.25))
        .markdownMargin(top: 0, bottom: 16)
    }
    .listItem { configuration in
      configuration.label
        .markdownMargin(top: .em(0.25))
    }
    // More block styles...
}
```

### Limiting decoded image size

The default block and inline image providers share downloads and decoded images for
matching URLs and resolutions. Both preserve original resolution by default. For
large source images, configure a maximum decoded pixel dimension:

```swift
MarkdownView(markdownString)
  .markdownImageProvider(DefaultImageProvider(resolution: .maximumPixelDimension(1200)))
  .markdownInlineImageProvider(DefaultInlineImageProvider(resolution: .maximumPixelDimension(1200)))
```

The limit applies to the longest decoded dimension and also changes the image's
intrinsic layout size. Choose it with the desired display size and screen scale in
mind. The decoded-image cache budget does not include images retained by visible
views, downloads in progress, or active decoding allocations.
