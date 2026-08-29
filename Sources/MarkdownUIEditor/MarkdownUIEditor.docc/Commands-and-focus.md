# Commands and focus

``MarkdownEditorCommand`` describes a typed editing action. Native text views expose `canPerform(_:)` and `perform(_:)`.

```swift
import MarkdownUIEditor
import UIKit

let textView = MarkdownTextView(usingTextLayoutManager: true)
textView.document = MarkdownDocument(markdown: "A sentence")

let command = MarkdownEditorCommand.toggleInline(.strong)
if textView.canPerform(command) {
    textView.perform(command)
}
```

Commands cover inline styling, block and list conversion, links, images, indentation, task state, thematic breaks, and table edits. A structural command is one native undo operation. Inline formatting and list conversion also support selections spanning multiple blocks. An inline command at a collapsed insertion point changes typing attributes, so subsequent text receives the style without inserting Markdown markers.

Select text and open its contextual menu to access **Style → Bold**, **Italic**, or **Strikethrough**. This works in ordinary document text and table cells, using a right-click on macOS or the text-editing menu on iOS. Table cells additionally offer the **Table** submenu for row, column, and alignment commands. The standard system editing actions remain available.

SwiftUI hosts can add controls that operate on the currently focused editor through ``MarkdownEditorContext``.

```swift
import MarkdownUIEditor
import SwiftUI

struct BoldButton: View {
    @FocusedValue(\.markdownEditorContext) private var editor

    var body: some View {
        Button("Bold") {
            editor?.perform(.toggleInline(.strong))
        }
        .disabled(editor?.canPerform(.toggleInline(.strong)) != true)
    }
}
```

The context is absent when no `MarkdownEditor` is focused. It never edits a background editor by accident.

`MarkdownEditorContext` is observable. Custom toolbars that retain a context should observe it with `@ObservedObject` and use `isActive(_:)` to display selected formatting. At a collapsed caret, inline commands apply to subsequent typing, including inside a table cell.
