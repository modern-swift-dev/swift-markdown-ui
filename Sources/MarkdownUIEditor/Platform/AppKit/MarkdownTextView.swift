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

        /// The URLs the editor may load images from. Defaults to
        /// ``MarkdownEditorImageLoadingPolicy/allowAll``.
        ///
        /// Setting the policy redraws the document, so images it now blocks show their alternative
        /// text and images it now allows load.
        public var imageLoadingPolicy: MarkdownEditorImageLoadingPolicy {
            get { editingSession.imageLoadingPolicy }
            set {
                attachEditingSessionIfNeeded()
                editingSession.replaceImageLoadingPolicy(newValue)
            }
        }

        /// Whether people can change the document.
        ///
        /// When `false`, typing, pasting, dropping, table cells, task checkboxes,
        /// editing commands, and Undo and Redo leave the document unchanged. People can
        /// still select and copy text and open links. The undo history is kept, so Undo
        /// works again once the editor is editable.
        override public var isEditable: Bool {
            didSet {
                guard isEditable != oldValue, hasAttachedEditingSession else {
                    return
                }
                editingSession.editabilityDidChange()
            }
        }

        /// Whether typing a Markdown block marker at the start of a paragraph converts it,
        /// such as `# ` to a heading or `- ` to a bulleted list. Off by default.
        ///
        /// Undo right after a conversion restores the typed characters as text.
        public var convertsMarkdownShortcuts: Bool {
            get { editingSession.convertsMarkdownShortcuts }
            set { editingSession.convertsMarkdownShortcuts = newValue }
        }

        /// Presents the SwiftUI editor's link dialog. ⌘K is handled only while it is set.
        var presentLinkEditor: (() -> Void)?

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
        /// Exposes each drawn checkbox to assistive technologies.
        private lazy var taskCheckboxElements: [MarkdownTaskCheckboxAccessibilityElement] = []

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
                    taskCheckboxElements.append(MarkdownTaskCheckboxAccessibilityElement(textView: self))
                }
                taskCheckboxLayers[count].update(textRect: textRect, checked: checked.boolValue, color: taskCheckboxColor, theme: editorTheme)
                taskCheckboxElements[count].update(offset: offset, checked: checked.boolValue, frame: taskCheckboxLayers[count].frame)
                count += 1
            }
            while taskCheckboxLayers.count > count {
                taskCheckboxLayers.removeLast().removeFromSuperlayer()
                taskCheckboxElements.removeLast()
            }
        }

        override public func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            let color = taskCheckboxColor
            for checkbox in taskCheckboxLayers {
                checkbox.strokeColor = color
            }
        }

        /// The label color in this view's appearance, which layers can't resolve themselves.
        private var taskCheckboxColor: CGColor {
            var color = NSColor.labelColor.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance {
                color = NSColor.labelColor.cgColor
            }
            return color
        }

        override public func accessibilityChildren() -> [Any]? {
            (super.accessibilityChildren() ?? []) + taskCheckboxElements
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

        /// Indents the list item at the caret. Outside a list, Tab keeps its standard behavior.
        override public func insertTab(_ sender: Any?) {
            guard handlesEditorShortcuts, editingSession.selectionIsInListItem else {
                super.insertTab(sender)
                return
            }
            perform(.indent)
        }

        /// Outdents the list item at the caret, turning a top-level item into a paragraph.
        /// Outside a list, Shift-Tab keeps its standard behavior.
        override public func insertBacktab(_ sender: Any?) {
            guard handlesEditorShortcuts, editingSession.selectionIsInListItem else {
                super.insertBacktab(sender)
                return
            }
            perform(.outdent)
        }

        override public func keyDown(with event: NSEvent) {
            // Shift-Return inserts a hard line break, saved as a trailing backslash.
            if event.charactersIgnoringModifiers == "\r",
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift,
               handlesEditorShortcuts,
               editingSession.insertHardLineBreak() {
                return
            }
            super.keyDown(with: event)
        }

        override public func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard handlesEditorShortcuts else {
                return super.performKeyEquivalent(with: event)
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
                case ("x", [.command, .shift]) where canPerform(.toggleInline(.strikethrough)):
                    perform(.toggleInline(.strikethrough))
                    return true
                case ("k", .command) where presentLinkEditor != nil && canPerform(.setLink(destination: "", title: nil)):
                    presentLinkEditor?()
                    return true
                default:
                    return super.performKeyEquivalent(with: event)
            }
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
                case #selector(undo(_:)):
                    validateUndoItem(item, title: \.undoMenuItemTitle, isAvailable: \.canUndo)
                case #selector(redo(_:)):
                    validateUndoItem(item, title: \.redoMenuItemTitle, isAvailable: \.canRedo)
                default:
                    super.validateUserInterfaceItem(item)
            }
        }

        /// Handles the Edit menu's Undo before the window does, so a read-only editor ignores it.
        @objc func undo(_ sender: Any?) {
            guard isEditable else {
                return
            }
            undoManager?.undo()
        }

        /// Handles the Edit menu's Redo before the window does, so a read-only editor ignores it.
        @objc func redo(_ sender: Any?) {
            guard isEditable else {
                return
            }
            undoManager?.redo()
        }

        /// Names the Undo or Redo menu item after the change it reverts, as the window does.
        /// The item is disabled while the editor is read-only; its history is kept.
        private func validateUndoItem(
            _ item: any NSValidatedUserInterfaceItem,
            title: KeyPath<UndoManager, String>,
            isAvailable: KeyPath<UndoManager, Bool>
        ) -> Bool {
            guard let undoManager else {
                return false
            }
            (item as? NSMenuItem)?.title = undoManager[keyPath: title]
            return isEditable && undoManager[keyPath: isAvailable]
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
                if command == .toggleInline(.strikethrough) {
                    item.keyEquivalent = "x"
                    item.keyEquivalentModifierMask = [.command, .shift]
                }
                styleMenu.addItem(item)
            }
            let styleItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
            styleItem.submenu = styleMenu
            menu.addItem(styleItem)
            if presentLinkEditor != nil {
                let linkItem = NSMenuItem(title: "Add or Edit Link…", action: #selector(presentLinkEditorFromMenu(_:)), keyEquivalent: "k")
                linkItem.target = self
                linkItem.keyEquivalentModifierMask = .command
                menu.addItem(linkItem)
            }
            return menu
        }

        @objc private func presentLinkEditorFromMenu(_ sender: NSMenuItem) {
            presentLinkEditor?()
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

        /// AppKit asks whether the first marked text may change storage before it reports marked
        /// text, so the composition is announced first, as on UIKit.
        override public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
            attachEditingSessionIfNeeded()
            editingSession.compositionWillChangeCharacters(in: replacementRange.location == NSNotFound
                ? (hasMarkedText() ? markedRange() : self.selectedRange())
                : replacementRange)
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        }

        /// AppKit commits marked text here without posting a text change.
        override public func unmarkText() {
            super.unmarkText()
            notifyCompositionEndIfNeeded()
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
            // The plain-text fallback below must not convert a pasted marker either.
            editingSession.isPasting = true
            defer { editingSession.isPasting = false }
            guard let payload = MarkdownEditorClipboard.read(), editingSession.paste(payload) else {
                super.paste(sender)
                return
            }
        }
    }

    extension MarkdownTextView {
        /// Scrolls to the heading a same-document link such as `#hello-world` points to.
        /// Returns `false`, without scrolling, for other links and unmatched fragments.
        func scrollToHeading(linkDestination: String) -> Bool {
            guard let range = editingSession.headingProjectionRange(forLinkDestination: linkDestination) else {
                return false
            }
            scrollRangeToVisible(range)
            return true
        }
    }

    private extension MarkdownTextView {
        /// Editor shortcuts apply only while this view itself has focus and accepts edits,
        /// so they never fire while a table cell or another view has focus.
        var handlesEditorShortcuts: Bool {
            attachEditingSessionIfNeeded()
            return editingSession.acceptsEditorShortcuts
        }

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

    /// Exposes one drawn task checkbox as a checkbox that toggles its task.
    @MainActor final class MarkdownTaskCheckboxAccessibilityElement: NSAccessibilityElement {
        /// AppKit declares the accessibility methods below nonisolated but calls them on the
        /// main thread, so they read these properties there and hop onto the main actor.
        private nonisolated(unsafe) weak var textView: MarkdownTextView?
        /// The projected offset of the task item's first leaf.
        private nonisolated(unsafe) var offset = 0

        init(textView: MarkdownTextView) {
            self.textView = textView
            super.init()
            setAccessibilityRole(.checkBox)
            setAccessibilityParent(textView)
        }

        func update(offset: Int, checked: Bool, frame: CGRect) {
            self.offset = offset
            setAccessibilityValue(NSNumber(value: checked))
            setAccessibilityFrameInParentSpace(frame)
        }

        override func accessibilityLabel() -> String? {
            let textView = textView, offset = offset
            return MainActor.assumeIsolated {
                textView?.editingSession.taskCheckboxLabel(atProjectionUTF16Offset: offset)
            }
        }

        override func accessibilityPerformPress() -> Bool {
            let textView = textView, offset = offset
            return MainActor.assumeIsolated {
                textView?.editingSession.toggleTask(atProjectionUTF16Offset: offset) ?? false
            }
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

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            // Returning false keeps AppKit's default handling for every other link.
            guard let destination = (link as? String) ?? (link as? URL)?.relativeString else {
                return false
            }
            return owner?.scrollToHeading(linkDestination: destination) ?? false
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

        var markdownIsEditable: Bool {
            isEditable
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
