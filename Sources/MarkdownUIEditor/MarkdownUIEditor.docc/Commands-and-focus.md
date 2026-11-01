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

Commands cover inline styling, block and list conversion, links, images, indentation, task state, thematic breaks, and table edits. A structural command is one native undo operation. Inline formatting and list conversion also support selections spanning multiple blocks. Choosing an active heading level, quote, or list style toggles it off: the heading becomes a paragraph, the quoted block leaves its quote, and the selected list items become paragraphs. An inline command at a collapsed insertion point changes typing attributes, so subsequent text receives the style without inserting Markdown markers.

Select text and open its contextual menu to access **Style → Bold**, **Italic**, or **Strikethrough**. This works in ordinary document text and table cells, using a right-click on macOS or the text-editing menu on iOS. Table cells additionally offer the **Table** submenu for row, column, and alignment commands. The standard system editing actions remain available.

## Keyboard shortcuts

While the editor itself has keyboard focus, these shortcuts apply on macOS and with a hardware keyboard on iOS:

- **Tab** and **Shift-Tab** indent and outdent the list item at the caret. Shift-Tab on a top-level item turns it into a paragraph. Outside a list, both keep their standard behavior, and table cells keep using them to move between cells.
- **Shift-Return** inserts a hard line break in a paragraph, saved as a trailing backslash (`\`).
- **Shift-Command-X** toggles strikethrough.
- **Command-K** opens the "Add or edit link" dialog of the SwiftUI `MarkdownEditor`. `MarkdownTextView` used directly has no Command-K, so apps add their own link interface.

The shortcuts don't fire while a table cell or another view has focus. On iOS, they appear in the hardware keyboard's discoverability overlay.

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
