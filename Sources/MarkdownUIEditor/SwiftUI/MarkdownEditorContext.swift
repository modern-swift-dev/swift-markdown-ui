#if canImport(SwiftUI) && (os(iOS) || os(macOS) || targetEnvironment(macCatalyst))
    import SwiftUI

    /// The command target for the focused ``MarkdownEditor``.
    @MainActor public final class MarkdownEditorContext: ObservableObject {
        private weak var textView: MarkdownTextView?
        private var updateScheduled = false
        private var cachedCommandState: MarkdownEditorCommandState?

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

        /// The toolbar's command state, evaluated once after each editor change.
        var commandState: MarkdownEditorCommandState {
            if let cachedCommandState {
                return cachedCommandState
            }
            let state = MarkdownEditorCommandState(canPerform: canPerform, isActive: isActive)
            cachedCommandState = state
            return state
        }

        /// Applies a command and returns keyboard focus to the editor.
        public func perform(_ command: MarkdownEditorCommand) {
            guard canPerform(command) else {
                return
            }
            textView?.perform(command)
        }

        func setTextView(_ textView: MarkdownTextView?) {
            // Representable updates can replace the document without a command-state callback.
            cachedCommandState = nil
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
            cachedCommandState = nil
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

    /// Immutable command availability and formatting state for the formatting toolbar.
    struct MarkdownEditorCommandState {
        /// Every command the formatting toolbar displays.
        static let toolbarCommands: [MarkdownEditorCommand] = [
            .toggleInline(.strong),
            .toggleInline(.emphasis),
            .toggleInline(.strikethrough),
            .toggleInline(.code),
            .convertBlock(.paragraph)
        ] + MarkdownHeadingLevel.allCases.map { .convertBlock(.heading($0)) } + [
            .convertBlock(.blockquote),
            .convertBlock(.code(info: nil)),
            .insertThematicBreak,
            .convertList(.unordered),
            .convertList(.ordered(start: 1)),
            .convertList(.task),
            .toggleTask,
            .indent,
            .outdent,
            .insertTable(columns: 2, bodyRows: 2),
            .insertTableRow,
            .deleteTableRow,
            .moveTableRow(.backward),
            .moveTableRow(.forward),
            .insertTableColumn,
            .deleteTableColumn,
            .moveTableColumn(.backward),
            .moveTableColumn(.forward),
            .setTableColumnAlignment(.left),
            .setTableColumnAlignment(.center),
            .setTableColumnAlignment(.right),
            linkPlaceholder,
            .removeLink,
            imagePlaceholder
        ]
        static let linkPlaceholder = MarkdownEditorCommand.setLink(destination: "https://", title: nil)
        static let imagePlaceholder = MarkdownEditorCommand.insertImage(source: "https://", title: nil, alt: "")

        private let available: [MarkdownEditorCommand: Bool]
        private let active: [MarkdownEditorCommand: Bool]

        init(
            commands: [MarkdownEditorCommand] = toolbarCommands,
            canPerform: (MarkdownEditorCommand) -> Bool,
            isActive: (MarkdownEditorCommand) -> Bool
        ) {
            available = Dictionary(uniqueKeysWithValues: commands.map { ($0, canPerform($0)) })
            active = Dictionary(uniqueKeysWithValues: commands.map { ($0, isActive($0)) })
        }

        func canPerform(_ command: MarkdownEditorCommand) -> Bool {
            assert(available[command] != nil, "The toolbar command state does not include \(command)")
            return available[command] ?? false
        }

        func isActive(_ command: MarkdownEditorCommand) -> Bool {
            assert(active[command] != nil, "The toolbar command state does not include \(command)")
            return active[command] ?? false
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
