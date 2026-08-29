import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit) || canImport(AppKit)
/// The small platform-specific interface consumed by `MarkdownEditingSession`.
///
/// AppKit and UIKit adapters keep their native view code out of the session.
@MainActor protocol TextViewBridge: AnyObject {
    /// Native storage containing the current rich-text projection.
    var markdownTextStorage: NSTextStorage { get }
    /// Native selections, expressed in projection UTF-16 offsets.
    var markdownSelectedRanges: [NSRange] { get set }
    /// Native attributes used by TextKit for text inserted at a collapsed selection.
    var markdownTypingAttributes: [NSAttributedString.Key: Any] { get set }
    /// Whether the platform currently owns an IME composition.
    var markdownHasMarkedText: Bool { get }
    /// Whether the outer editor currently owns keyboard focus.
    var markdownIsFirstResponder: Bool { get }
    /// Native undo manager used to group document changes.
    var undoManager: UndoManager? { get }

    /// Replaces projection text while the session restores its own state.
    func replaceAttributedCharacters(in range: NSRange, with replacement: NSAttributedString)
}

extension TextViewBridge {
    var markdownIsFirstResponder: Bool {
        false
    }
}
#endif
