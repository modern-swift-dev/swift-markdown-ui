#if os(macOS) && canImport(AppKit)
    import AppKit

    /// Receives document changes made through a ``MarkdownTextView``.
    @MainActor public protocol MarkdownTextViewDelegate: AnyObject {
        /// Receives the parsed document after a user-initiated text change.
        func markdownTextView(_ textView: MarkdownTextView, didChange document: MarkdownDocument)
    }

    /// A native AppKit Markdown editor backed by TextKit 2.
    ///
    /// Create this view with `MarkdownTextView(usingTextLayoutManager: true)`.
    @MainActor public final class MarkdownTextView: NSTextView {
        /// The Markdown document currently displayed by the text view.
        public var document: MarkdownDocument {
            get {
                editingSession.document
            }
            set {
                attachEditingSessionIfNeeded()
                editingSession.replaceDocument(newValue)
            }
        }

        /// The recipient of document changes initiated in this text view.
        public weak var markdownDelegate: (any MarkdownTextViewDelegate)?

        /// The native text attributes used by the editor projection.
        public var editorTheme: MarkdownEditorTheme {
            get { editingSession.theme }
            set {
                attachEditingSessionIfNeeded()
                editingSession.replaceTheme(newValue)
            }
        }

        /// The URL used to resolve relative image destinations.
        public var baseURL: URL? {
            get { editingSession.baseURL }
            set {
                attachEditingSessionIfNeeded()
                editingSession.replaceObjectConfiguration(baseURL: newValue, imageProvider: editingSession.imageProvider)
            }
        }

        /// The asynchronous provider used by URL-backed image attachments.
        public var imageProvider: (any MarkdownEditorImageProvider)? {
            get { editingSession.imageProvider }
            set {
                attachEditingSessionIfNeeded()
                editingSession.replaceObjectConfiguration(baseURL: editingSession.baseURL, imageProvider: newValue)
            }
        }

        /// The empty document used before the lazy editing session attaches.
        private let initialDocument = MarkdownDocument()
        /// Prevents installing the session and native delegate more than once.
        private var hasAttachedEditingSession = false

        /// Owns the document, projection, selection mapping, and undo state.
        lazy var editingSession = MarkdownEditingSession(document: initialDocument) { [weak self] document in
            guard let self else {
                return
            }
            self.markdownDelegate?.markdownTextView(self, didChange: document)
        }

        /// Forwards AppKit delegate callbacks to the editing session.
        private lazy var coordinator = Coordinator(owner: self)
        private lazy var taskCheckboxLayers: [MarkdownTaskCheckboxLayer] = []

        override public func layout() {
            super.layout()
            guard hasAttachedEditingSession, let window else {
                return
            }
            wantsLayer = true
            var count = 0
            let index = editingSession.projection.index
            let visibleRange = if let manager = textLayoutManager,
                                  let contentManager = manager.textContentManager,
                                  let viewport = manager.textViewportLayoutController.viewportRange {
                ProjectionUTF16Range(
                    location: contentManager.offset(from: contentManager.documentRange.location, to: viewport.location),
                    length: contentManager.offset(from: viewport.location, to: viewport.endLocation)
                )
            } else {
                ProjectionUTF16Range(location: 0, length: index.projectionUTF16Length)
            }
            for offset in index.unitStartOffsets(in: visibleRange) {
                guard let storage = textStorage, offset < storage.length,
                      let checked = storage.attribute(.markdownEditorTaskChecked, at: offset, effectiveRange: nil) as? NSNumber else {
                    continue
                }
                var actualRange = NSRange()
                let screenRect = firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: &actualRange)
                let textRect = convert(window.convertFromScreen(screenRect), from: nil)
                if count == taskCheckboxLayers.count {
                    let checkbox = MarkdownTaskCheckboxLayer()
                    layer?.addSublayer(checkbox)
                    taskCheckboxLayers.append(checkbox)
                }
                taskCheckboxLayers[count].update(textRect: textRect, checked: checked.boolValue, color: NSColor.labelColor.cgColor, theme: editorTheme)
                count += 1
            }
            while taskCheckboxLayers.count > count {
                taskCheckboxLayers.removeLast().removeFromSuperlayer()
            }
        }

        /// Applies a structural Markdown editing command to the current selection.
        public func perform(_ command: MarkdownEditorCommand) {
            attachEditingSessionIfNeeded()
            guard canPerform(command) else {
                return
            }
            if !editingSession.hasActiveTableSelection {
                if window?.firstResponder !== self {
                    let ranges = selectedRanges
                    window?.makeFirstResponder(self)
                    selectedRanges = ranges
                }
            }
            editingSession.perform(command)
        }

        /// Returns whether this view can apply a command to its current selection.
        public func canPerform(_ command: MarkdownEditorCommand) -> Bool {
            attachEditingSessionIfNeeded()
            return editingSession.canPerform(command)
        }

        override public func becomeFirstResponder() -> Bool {
            attachEditingSessionIfNeeded()
            let accepted = super.becomeFirstResponder()
            editingSession.onCommandStateChange?()
            return accepted
        }

        @IBAction public func toggleBoldface(_ sender: Any?) {
            perform(.toggleInline(.strong))
        }

        @IBAction public func toggleItalics(_ sender: Any?) {
            perform(.toggleInline(.emphasis))
        }

        @IBAction public func toggleStrikethrough(_ sender: Any?) {
            perform(.toggleInline(.strikethrough))
        }

        @IBAction public func toggleUnorderedList(_ sender: Any?) {
            perform(.convertList(.unordered))
        }

        @IBAction public func toggleOrderedList(_ sender: Any?) {
            perform(.convertList(.ordered(start: 1)))
        }

        override public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
            switch item.action {
                case #selector(toggleBoldface(_:)):
                    canPerform(.toggleInline(.strong))
                case #selector(toggleItalics(_:)):
                    canPerform(.toggleInline(.emphasis))
                case #selector(toggleStrikethrough(_:)):
                    canPerform(.toggleInline(.strikethrough))
                case #selector(toggleUnorderedList(_:)):
                    canPerform(.convertList(.unordered))
                case #selector(toggleOrderedList(_:)):
                    canPerform(.convertList(.ordered(start: 1)))
                default:
                    super.validateUserInterfaceItem(item)
            }
        }

        override public func menu(for event: NSEvent) -> NSMenu? {
            let selection = markdownSelectedRanges
            let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
            if selection.contains(where: { $0.length > 0 }) {
                markdownSelectedRanges = selection
            }
            guard selectedRange.length > 0 else {
                return menu
            }
            menu.addItem(.separator())
            let styleMenu = NSMenu(title: "Style")
            styleMenu.autoenablesItems = false
            for (title, command) in MarkdownEditorCommand.contextualInlineCommands {
                let item = NSMenuItem(title: title, action: #selector(performContextFormatting(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = command
                item.isEnabled = canPerform(command)
                styleMenu.addItem(item)
            }
            let styleItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
            styleItem.submenu = styleMenu
            menu.addItem(styleItem)
            return menu
        }

        @objc private func performContextFormatting(_ sender: NSMenuItem) {
            guard let command = sender.representedObject as? MarkdownEditorCommand else {
                return
            }
            perform(command)
        }

        override public func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let offset = taskMarkerOffset(at: point),
               editingSession.toggleTask(atProjectionUTF16Offset: offset) {
                return
            }
            super.mouseDown(with: event)
        }

        override public func copy(_ sender: Any?) {
            guard let payload = editingSession.clipboardPayload(),
                  let markdown = payload.markdown,
                  let plainText = payload.plainText else {
                super.copy(sender)
                return
            }
            MarkdownEditorClipboard.write(markdown: markdown, plainText: plainText)
        }

        override public func paste(_ sender: Any?) {
            guard let payload = MarkdownEditorClipboard.read(), editingSession.paste(payload) else {
                super.paste(sender)
                return
            }
        }
    }

    private extension MarkdownTextView {
        func taskMarkerOffset(at point: NSPoint) -> Int? {
            let offset = characterIndexForInsertion(at: point)
            guard let range = editingSession.taskItemProjectionRange(containing: offset),
                  let window else {
                return nil
            }
            var actualRange = NSRange()
            let textRectOnScreen = firstRect(
                forCharacterRange: NSRange(location: range.location, length: min(1, range.length)),
                actualRange: &actualRange
            )
            let textRect = convert(window.convertFromScreen(textRectOnScreen), from: nil)
            let markerBounds = MarkdownTaskCheckboxLayer.hitBounds(textRect: textRect, theme: editorTheme)
            return markerBounds.contains(point) ? range.location : nil
        }

        func attachEditingSessionIfNeeded() {
            guard !hasAttachedEditingSession else {
                return
            }
            guard textLayoutManager != nil else {
                preconditionFailure("MarkdownTextView requires TextKit 2. Use init(usingTextLayoutManager: true).")
            }

            allowsUndo = true
            isAutomaticSpellingCorrectionEnabled = true
            isAutomaticTextCompletionEnabled = true
            isAutomaticQuoteSubstitutionEnabled = true
            isAutomaticDashSubstitutionEnabled = true
            isAutomaticDataDetectionEnabled = true
            usesFindBar = true
            delegate = coordinator
            coordinator.observeUndoManager()
            hasAttachedEditingSession = true
            editingSession.attach(to: self)
        }
    }

    @MainActor private final class Coordinator: NSObject, NSTextViewDelegate {
        /// The text view whose callbacks this coordinator forwards.
        weak var owner: MarkdownTextView?

        init(owner: MarkdownTextView) {
            self.owner = owner
        }

        func observeUndoManager() {
            // Resolve the owner's current manager in the callback because attaching
            // to a window or moving between windows can change it.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(undoManagerDidChange(_:)),
                name: .NSUndoManagerDidUndoChange,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(undoManagerDidChange(_:)),
                name: .NSUndoManagerDidRedoChange,
                object: nil
            )
        }

        @objc private func undoManagerDidChange(_ notification: Notification) {
            guard let owner,
                  let manager = notification.object as? UndoManager,
                  manager === owner.undoManager else {
                return
            }
            owner.editingSession.undoManagerDidChange()
        }

        func textDidChange(_ notification: Notification) {
            owner?.textDidChange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            owner?.selectionDidChange()
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            owner?.editingSession.shouldReplaceCharacters(
                in: affectedCharRange,
                with: replacementString ?? ""
            ) ?? true
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextInRanges affectedRanges: [NSValue],
            replacementStrings: [String]?
        ) -> Bool {
            guard let replacementStrings else {
                if affectedRanges.count > 1 {
                    return owner?.editingSession.shouldReplaceCharacters(
                        in: affectedRanges.map(\.rangeValue),
                        with: Array(repeating: "", count: affectedRanges.count)
                    ) ?? true
                }
                return owner?.editingSession.shouldReplaceCharacters(
                    in: affectedRanges[0].rangeValue,
                    with: ""
                ) ?? true
            }
            guard replacementStrings.count == affectedRanges.count else {
                return true
            }
            if affectedRanges.count > 1 {
                return owner?.editingSession.shouldReplaceCharacters(
                    in: affectedRanges.map(\.rangeValue),
                    with: replacementStrings
                ) ?? true
            }
            return owner?.editingSession.shouldReplaceCharacters(
                in: affectedRanges[0].rangeValue,
                with: replacementStrings[0]
            ) ?? true
        }

        func textDidEndEditing(_ notification: Notification) {
            owner?.editingSession.compositionDidEnd()
        }
    }

    private extension MarkdownTextView {
        func textDidChange() {
            editingSession.storageDidChange()
            needsLayout = true
            notifyCompositionEndIfNeeded()
        }

        func selectionDidChange() {
            editingSession.selectionDidChange()
            notifyCompositionEndIfNeeded()
        }

        func notifyCompositionEndIfNeeded() {
            guard !markdownHasMarkedText else {
                return
            }
            editingSession.compositionDidEnd()
        }
    }

    extension MarkdownTextView: TextViewBridge {
        /// The storage mutated by AppKit and observed by the editing session.
        var markdownTextStorage: NSTextStorage {
            guard let textStorage else {
                preconditionFailure("MarkdownTextView must have a text storage")
            }
            return textStorage
        }

        /// All native selections, expressed in projection UTF-16 offsets.
        var markdownSelectedRanges: [NSRange] {
            get {
                selectedRanges.map(\.rangeValue)
            }
            set {
                selectedRanges = newValue.map(NSValue.init(range:))
            }
        }

        /// AppKit's attributes used when native typing inserts a character.
        var markdownTypingAttributes: [NSAttributedString.Key: Any] {
            get { typingAttributes }
            set { typingAttributes = newValue }
        }

        var markdownIsFirstResponder: Bool {
            window?.firstResponder === self
        }

        /// Whether AppKit currently owns a marked-text composition.
        var markdownHasMarkedText: Bool {
            hasMarkedText()
        }

        /// Replaces projected text without adding the projection refresh to undo history.
        func replaceAttributedCharacters(in range: NSRange, with replacement: NSAttributedString) {
            let undoManager = undoManager
            let wasUndoRegistrationEnabled = undoManager?.isUndoRegistrationEnabled ?? false
            if wasUndoRegistrationEnabled {
                undoManager?.disableUndoRegistration()
            }
            markdownTextStorage.replaceCharacters(in: range, with: replacement)
            needsLayout = true
            if wasUndoRegistrationEnabled {
                undoManager?.enableUndoRegistration()
            }
        }
    }
#endif
