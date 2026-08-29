# Platform behavior

On iOS and Mac Catalyst, `MarkdownTextView` subclasses `UITextView`. It supports touch selection, Dynamic Type, the native undo manager, hardware keyboard commands, edit menus, drag and drop, and an input assistant with bold and italic actions.

On macOS, `MarkdownTextView` subclasses `NSTextView`. `MarkdownEditor` places it in an `NSScrollView`. The view uses the responder chain for standard commands and supports the Format menu, keyboard shortcuts, find, spelling, substitutions, mouse selection, services, and native undo.

Both platforms use TextKit 2. Their public editor APIs are the same where UIKit and AppKit permit it: set `document`, assign `editorTheme`, observe `markdownDelegate`, and call `canPerform(_:)` or `perform(_:)`.
