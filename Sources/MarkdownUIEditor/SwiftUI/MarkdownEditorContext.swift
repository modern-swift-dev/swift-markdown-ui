#if canImport(SwiftUI) && (os(iOS) || os(macOS) || targetEnvironment(macCatalyst))
import SwiftUI

/// The command target for the focused ``MarkdownEditor``.
@MainActor public final class MarkdownEditorContext: ObservableObject {
    private weak var textView: MarkdownTextView?
    private var updateScheduled = false

    /// Creates an empty context that becomes active when an editor attaches.
    public init() {}

    /// Returns whether the editor can apply a command to its current selection.
    public func canPerform(_ command: MarkdownEditorCommand) -> Bool {
        textView?.canPerform(command) ?? false
    }

    /// Returns whether the current selection already has the requested formatting.
    public func isActive(_ command: MarkdownEditorCommand) -> Bool {
        textView?.editingSession.isActive(command) ?? false
    }

    /// Applies a command and returns keyboard focus to the editor.
    public func perform(_ command: MarkdownEditorCommand) {
        guard canPerform(command) else {
            return
        }
        textView?.perform(command)
    }

    func setTextView(_ textView: MarkdownTextView?) {
        guard self.textView !== textView else {
            return
        }
        self.textView?.editingSession.onCommandStateChange = nil
        self.textView = textView
        textView?.editingSession.onCommandStateChange = { [weak self] in
            self?.scheduleUpdate()
        }
        scheduleUpdate()
    }

    private func scheduleUpdate() {
        guard !updateScheduled else {
            return
        }
        updateScheduled = true
        // Native selection callbacks can arrive during a representable update.
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            self.updateScheduled = false
            self.objectWillChange.send()
        }
    }
}

private struct MarkdownEditorContextKey: FocusedValueKey {
    typealias Value = MarkdownEditorContext
}

public extension FocusedValues {
    /// The context for the currently focused Markdown editor.
    var markdownEditorContext: MarkdownEditorContext? {
        get { self[MarkdownEditorContextKey.self] }
        set { self[MarkdownEditorContextKey.self] = newValue }
    }
}
#endif
