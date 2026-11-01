# Platform behavior

On iOS and Mac Catalyst, `MarkdownTextView` subclasses `UITextView`. It supports touch selection, Dynamic Type, the native undo manager, hardware keyboard commands, edit menus, drag and drop, and an input assistant with bold and italic actions.

Dynamic Type applies on UIKit only. The built-in themes scale body, heading, code, and table cell text with the view's content size category, keeping their sizes relative to each other, and the editor renders the document again at the new size when the text size changes, keeping the selection. Custom themes keep their font sizes unless they opt in with `adjustsFontForContentSizeCategory`; their fonts are then the sizes at the default (Large) category and scale like the built-in themes.

On macOS, `MarkdownTextView` subclasses `NSTextView`. AppKit has no content size category, so theme fonts keep their sizes. `MarkdownEditor` places it in an `NSScrollView`. The view uses the responder chain for standard commands and supports the Format menu, keyboard shortcuts, find, spelling, substitutions, mouse selection, services, and native undo.

Both platforms use TextKit 2. Their public editor APIs are the same where UIKit and AppKit permit it: set `document`, assign `editorTheme`, observe `markdownDelegate`, and call `canPerform(_:)` or `perform(_:)`.
