# Native text views

For UIKit and AppKit applications that do not use SwiftUI, create `MarkdownTextView` with `usingTextLayoutManager: true`. That initializer selects TextKit 2, which the editor requires.

```swift
import MarkdownUIEditor
import UIKit

let textView = MarkdownTextView(usingTextLayoutManager: true)
textView.document = MarkdownDocument(markdown: "# Draft")
textView.editorTheme = .docC
```

The same construction applies to AppKit, with `import AppKit` instead of `import UIKit`.

Set ``MarkdownTextView/markdownDelegate`` to receive changes made by the user.

```swift
import MarkdownUIEditor
import UIKit

final class EditorDelegate: NSObject, MarkdownTextViewDelegate {
    func markdownTextView(_ textView: MarkdownTextView, didChange document: MarkdownDocument) {
        print(document.markdown)
    }
}
```

Set ``MarkdownTextView/document`` when external state replaces the document. The editor rebuilds its rich projection and restores the closest valid selection. Ordinary typing takes a localized path and does not recreate unrelated attachments.
