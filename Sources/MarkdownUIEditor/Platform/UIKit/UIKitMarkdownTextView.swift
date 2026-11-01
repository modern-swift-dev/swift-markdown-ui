#if os(iOS) || targetEnvironment(macCatalyst)
    import UIKit

    /// Receives changes made by a ``MarkdownTextView``.
    @MainActor public protocol MarkdownTextViewDelegate: AnyObject {
        /// Receives the parsed document after a user-initiated text change.
        func markdownTextView(_ textView: MarkdownTextView, didChange document: MarkdownDocument)
    }

    /// A native TextKit 2 markdown editor for iOS and Mac Catalyst.
    ///
    /// Construct this view with `MarkdownTextView(usingTextLayoutManager: true)`.
    @MainActor public final class MarkdownTextView: UITextView {
        /// The recipient of document changes initiated in this text view.
        public weak var markdownDelegate: (any MarkdownTextViewDelegate)?

        /// The native text attributes used by the editor projection.
        ///
        /// When the theme adjusts its fonts for the content size category, the editor
        /// renders them at this view's `preferredContentSizeCategory`.
        public var editorTheme: MarkdownEditorTheme {
            get { editingSession.configuredTheme }
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

        /// Hidden while the editor is read-only: ⌘Z, the Edit menu, shake to undo and the
        /// shortcuts bar all undo through the first responder's undo manager.
        override public var undoManager: UndoManager? {
            isEditable ? super.undoManager : nil
        }

        /// The document displayed by the editor.
        public var document: MarkdownDocument {
            get {
                attachEditingSessionIfNeeded()
                return editingSession.document
            }
            set {
                attachEditingSessionIfNeeded()
                editingSession.replaceDocument(newValue)
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

        /// Presents the SwiftUI editor's link dialog. ⌘K is offered only while it is set.
        var presentLinkEditor: (() -> Void)?

        /// Prevents installing the session and native delegate more than once.
        private var hasAttachedEditingSession = false
        /// Owns the document, projection, selection mapping, and undo state.
        lazy var editingSession = MarkdownEditingSession(document: MarkdownDocument()) { [weak self] document in
            guard let self else {
                return
            }
            self.markdownDelegate?.markdownTextView(self, didChange: document)
        }

        /// Forwards UIKit delegate callbacks to the editing session.
        private lazy var coordinator = Coordinator(owner: self)
        /// Recognizes taps only inside a rendered task-list marker.
        private var taskMarkerTapGesture: UITapGestureRecognizer?
        private lazy var taskCheckboxLayers: [MarkdownTaskCheckboxLayer] = []
        /// Exposes each drawn checkbox to VoiceOver.
        private lazy var taskCheckboxViews: [MarkdownTaskCheckboxAccessibilityView] = []
        /// The inputs of the last checkbox placement. Scrolling within one viewport range reuses it.
        private var taskCheckboxPlacement: TaskCheckboxPlacement?
        /// Set by explicit layout invalidations, such as a table attachment resizing without a storage edit.
        private var needsTaskCheckboxPlacement = true
        /// Incremented after every storage edit, including attribute-only task toggles.
        private var storageVersion = 0
        /// Number of checkbox placements computed. Tests use it to observe skipped layout passes.
        private(set) var taskCheckboxPlacementCount = 0
        /// Avoids recording the same edit again if UIKit also calls its delegate.
        fileprivate var isHandlingNativeInput = false

        override public func setNeedsLayout() {
            needsTaskCheckboxPlacement = true
            super.setNeedsLayout()
        }

        override public func layoutSubviews() {
            super.layoutSubviews()
            placeTaskCheckboxes()
        }

        /// Positions checkboxes for the task items in the viewport.
        ///
        /// Scrolling lays out again without moving text in content coordinates, so
        /// the previous placement is reused until one of its inputs changes.
        func placeTaskCheckboxes(force: Bool = false) {
            guard hasAttachedEditingSession else {
                return
            }
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
            let color = UIColor.label.resolvedColor(with: traitCollection).cgColor
            let placement = TaskCheckboxPlacement(
                visibleRange: visibleRange,
                width: bounds.width,
                textContainerInset: textContainerInset,
                storageVersion: storageVersion,
                theme: ObjectIdentifier(editingSession.theme),
                color: color
            )
            guard force || needsTaskCheckboxPlacement || placement != taskCheckboxPlacement else {
                return
            }
            needsTaskCheckboxPlacement = false
            taskCheckboxPlacement = placement
            taskCheckboxPlacementCount += 1
            var count = 0
            for offset in index.unitStartOffsets(in: visibleRange) {
                guard offset < textStorage.length,
                      let checked = textStorage.attribute(.markdownEditorTaskChecked, at: offset, effectiveRange: nil) as? NSNumber,
                      let position = position(from: beginningOfDocument, offset: offset) else {
                    continue
                }
                if count == taskCheckboxLayers.count {
                    let checkbox = MarkdownTaskCheckboxLayer()
                    layer.addSublayer(checkbox)
                    taskCheckboxLayers.append(checkbox)
                    let view = MarkdownTaskCheckboxAccessibilityView(textView: self)
                    addSubview(view)
                    taskCheckboxViews.append(view)
                }
                taskCheckboxLayers[count].update(textRect: caretRect(for: position), checked: checked.boolValue, color: color, theme: editingSession.theme)
                taskCheckboxViews[count].update(offset: offset, checked: checked.boolValue, frame: taskCheckboxLayers[count].frame)
                count += 1
            }
            while taskCheckboxLayers.count > count {
                taskCheckboxLayers.removeLast().removeFromSuperlayer()
                taskCheckboxViews.removeLast().removeFromSuperview()
            }
        }

        /// Applies a markdown editing command to the current selection.
        public func perform(_ command: MarkdownEditorCommand) {
            attachEditingSessionIfNeeded()
            guard canPerform(command) else {
                return
            }
            if !editingSession.hasActiveTableSelection {
                if !isFirstResponder {
                    let range = selectedRange
                    _ = becomeFirstResponder()
                    selectedRange = range
                }
            }
            editingSession.perform(command)
        }

        /// Returns whether this view can apply a command to its current selection.
        public func canPerform(_ command: MarkdownEditorCommand) -> Bool {
            attachEditingSessionIfNeeded()
            return editingSession.canPerform(command)
        }

        override public func insertText(_ text: String) {
            attachEditingSessionIfNeeded()
            guard !isHandlingNativeInput, markedTextRange == nil else {
                super.insertText(text)
                return
            }
            guard editingSession.shouldReplaceCharacters(in: selectedRange, with: text) else {
                return
            }
            isHandlingNativeInput = true
            defer { isHandlingNativeInput = false }
            super.insertText(text)
        }

        /// UIKit does not ask the delegate before marked text changes storage.
        override public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
            attachEditingSessionIfNeeded()
            editingSession.compositionWillChangeCharacters(in: self.selectedRange)
            super.setMarkedText(markedText, selectedRange: selectedRange)
        }

        override public func replace(_ range: UITextRange, withText text: String) {
            // UIKit applies this text input replacement even when the view is not editable.
            guard isEditable else {
                return
            }
            super.replace(range, withText: text)
        }

        override public func deleteBackward() {
            attachEditingSessionIfNeeded()
            guard !isHandlingNativeInput, markedTextRange == nil,
                  selectedRange.location != NSNotFound else {
                super.deleteBackward()
                return
            }
            let range: NSRange
            if selectedRange.length > 0 {
                range = selectedRange
            } else if selectedRange.location > 0 {
                range = (textStorage.string as NSString).rangeOfComposedCharacterSequence(at: selectedRange.location - 1)
            } else {
                super.deleteBackward()
                return
            }
            guard editingSession.shouldReplaceCharacters(in: range, with: "") else {
                return
            }
            isHandlingNativeInput = true
            defer { isHandlingNativeInput = false }
            super.deleteBackward()
        }

        override public func becomeFirstResponder() -> Bool {
            attachEditingSessionIfNeeded()
            let accepted = super.becomeFirstResponder()
            editingSession.onCommandStateChange?()
            return accepted
        }

        override public func didMoveToWindow() {
            super.didMoveToWindow()
            attachEditingSessionIfNeeded()
            configureNativeEditing()
        }

        override public var keyCommands: [UIKeyCommand]? {
            let commands = super.keyCommands ?? []
            return commands + [
                UIKeyCommand(
                    title: "Bold",
                    action: #selector(toggleStrong),
                    input: "b",
                    modifierFlags: .command
                ),
                UIKeyCommand(
                    title: "Italic",
                    action: #selector(toggleEmphasis),
                    input: "i",
                    modifierFlags: .command
                ),
                editorKeyCommand("Strikethrough", action: #selector(toggleStrikethrough), input: "x", modifierFlags: [.command, .shift]),
                editorKeyCommand("Indent", action: #selector(indentListItem), input: "\t"),
                editorKeyCommand("Outdent", action: #selector(outdentListItem), input: "\t", modifierFlags: .shift),
                editorKeyCommand("Line Break", action: #selector(insertHardLineBreak), input: "\r", modifierFlags: .shift)
            ] + (presentLinkEditor == nil ? [] : [
                editorKeyCommand("Add or Edit Link", action: #selector(presentLinkEditorFromKeyboard), input: "k", modifierFlags: .command)
            ])
        }

        private func editorKeyCommand(
            _ title: String,
            action: Selector,
            input: String,
            modifierFlags: UIKeyModifierFlags = []
        ) -> UIKeyCommand {
            let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifierFlags)
            command.discoverabilityTitle = title
            command.wantsPriorityOverSystemBehavior = true
            return command
        }

        override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            switch action {
                case #selector(toggleStrong):
                    canPerform(.toggleInline(.strong))
                case #selector(toggleEmphasis):
                    canPerform(.toggleInline(.emphasis))
                case #selector(toggleStrikethrough):
                    canPerform(.toggleInline(.strikethrough))
                case #selector(indentListItem),
                     #selector(outdentListItem):
                    // Outside a list, Tab and Shift-Tab keep their standard behavior.
                    handlesEditorShortcuts && editingSession.selectionIsInListItem
                case #selector(insertHardLineBreak):
                    handlesEditorShortcuts
                case #selector(presentLinkEditorFromKeyboard):
                    handlesEditorShortcuts && presentLinkEditor != nil && canPerform(.setLink(destination: "", title: nil))
                default:
                    super.canPerformAction(action, withSender: sender)
            }
        }

        fileprivate func nativeEditMenu(
            forTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard range.length > 0 else {
                return UIMenu(children: suggestedActions)
            }
            selectedRange = range
            let styles = UIMenu(title: "Style", children: MarkdownEditorCommand.contextualInlineCommands.map { title, command in
                UIAction(title: title, attributes: canPerform(command) ? [] : [.disabled]) { [weak self] _ in
                    guard let self else {
                        return
                    }
                    self.selectedRange = range
                    self.perform(command)
                }
            })
            return UIMenu(children: suggestedActions + [styles])
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

        @objc private func toggleStrong() {
            perform(.toggleInline(.strong))
        }

        @objc private func toggleEmphasis() {
            perform(.toggleInline(.emphasis))
        }

        @objc private func toggleStrikethrough() {
            perform(.toggleInline(.strikethrough))
        }

        @objc private func indentListItem() {
            perform(.indent)
        }

        @objc private func outdentListItem() {
            perform(.outdent)
        }

        @objc private func insertHardLineBreak() {
            // Where a hard break has no Markdown form, Shift-Return behaves like Return.
            if !editingSession.insertHardLineBreak() {
                insertText("\n")
            }
        }

        @objc private func presentLinkEditorFromKeyboard() {
            presentLinkEditor?()
        }

        /// Editor shortcuts apply only while this view itself has focus and accepts edits,
        /// so they never fire while a table cell or another view has focus.
        private var handlesEditorShortcuts: Bool {
            attachEditingSessionIfNeeded()
            return editingSession.acceptsEditorShortcuts
        }

        @objc private func textStorageDidProcessEditing() {
            storageVersion &+= 1
        }

        @objc private func toggleTaskMarker(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let offset = taskMarkerOffset(at: recognizer.location(in: self)) else {
                return
            }
            editingSession.toggleTask(atProjectionUTF16Offset: offset)
        }

        fileprivate func textDidChange() {
            editingSession.storageDidChange()
            setNeedsLayout()
            notifyCompositionEndIfNeeded()
        }

        fileprivate func selectionDidChange() {
            editingSession.selectionDidChange()
            notifyCompositionEndIfNeeded()
        }

        fileprivate func notifyCompositionEndIfNeeded() {
            guard !markdownHasMarkedText else {
                return
            }
            editingSession.compositionDidEnd()
        }
    }

    /// Everything that positions task checkboxes in content coordinates.
    private struct TaskCheckboxPlacement: Equatable {
        var visibleRange: ProjectionUTF16Range
        var width: CGFloat
        var textContainerInset: UIEdgeInsets
        var storageVersion: Int
        var theme: ObjectIdentifier
        var color: CGColor
    }

    @MainActor extension MarkdownTextView: TextViewBridge {
        /// The storage mutated by UIKit and observed by the editing session.
        var markdownTextStorage: NSTextStorage {
            textStorage
        }

        /// UIKit's single selection, represented as a one-element range array.
        var markdownSelectedRanges: [NSRange] {
            get { [selectedRange] }
            set { selectedRange = newValue.first ?? NSRange(location: 0, length: 0) }
        }

        /// UIKit's attributes used when native typing inserts a character.
        var markdownTypingAttributes: [NSAttributedString.Key: Any] {
            get { typingAttributes }
            set { typingAttributes = newValue }
        }

        var markdownIsEditable: Bool {
            isEditable
        }

        var markdownIsFirstResponder: Bool {
            isFirstResponder
        }

        /// Whether UIKit currently owns a marked-text composition.
        var markdownHasMarkedText: Bool {
            markedTextRange != nil
        }

        /// Replaces projected text without adding the projection refresh to undo history.
        func replaceAttributedCharacters(in range: NSRange, with replacement: NSAttributedString) {
            let manager = undoManager
            let wasUndoRegistrationEnabled = manager?.isUndoRegistrationEnabled ?? false
            if wasUndoRegistrationEnabled {
                manager?.disableUndoRegistration()
            }
            defer {
                if wasUndoRegistrationEnabled,
                   manager?.isUndoRegistrationEnabled == false {
                    manager?.enableUndoRegistration()
                }
            }
            markdownTextStorage.replaceCharacters(in: range, with: replacement)
            setNeedsLayout()
        }
    }

    extension MarkdownTextView {
        /// Scrolls to the heading a same-document link such as `#hello-world` points to.
        /// Returns `false`, without scrolling, for other links and unmatched fragments.
        @discardableResult func scrollToHeading(linkDestination: String) -> Bool {
            guard let range = editingSession.headingProjectionRange(forLinkDestination: linkDestination),
                  let start = position(from: beginningOfDocument, offset: range.location) else {
                return false
            }
            // `scrollRangeToVisible(_:)` does not scroll this TextKit 2 view, so scroll to the heading's line.
            scrollRectToVisible(caretRect(for: start), animated: false)
            return true
        }
    }

    private extension MarkdownTextView {
        func attachEditingSessionIfNeeded() {
            assert(textLayoutManager != nil)
            assert(textContainer.textLayoutManager != nil)

            guard !hasAttachedEditingSession else {
                return
            }
            super.delegate = coordinator
            coordinator.observeUndoManager()
            NotificationCenter.default.addObserver(
                self, selector: #selector(textStorageDidProcessEditing),
                name: NSTextStorage.didProcessEditingNotification, object: textStorage
            )
            editingSession.replaceContentSizeCategory(traitCollection.preferredContentSizeCategory)
            editingSession.attach(to: self)
            hasAttachedEditingSession = true
            // Layers keep a resolved color, so checkboxes recolor as soon as the appearance changes.
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MarkdownTextView, _) in
                view.placeTaskCheckboxes()
            }
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: MarkdownTextView, _) in
                view.editingSession.replaceContentSizeCategory(view.traitCollection.preferredContentSizeCategory)
            }
        }

        func configureNativeEditing() {
            adjustsFontForContentSizeCategory = true

            let bold = UIBarButtonItem(title: "B", style: .plain, target: self, action: #selector(toggleStrong))
            bold.accessibilityLabel = "Bold"
            let italic = UIBarButtonItem(title: "I", style: .plain, target: self, action: #selector(toggleEmphasis))
            italic.accessibilityLabel = "Italic"
            inputAssistantItem.leadingBarButtonGroups = [
                UIBarButtonItemGroup(barButtonItems: [bold, italic], representativeItem: nil)
            ]

            if taskMarkerTapGesture == nil {
                let recognizer = UITapGestureRecognizer(target: self, action: #selector(toggleTaskMarker(_:)))
                recognizer.cancelsTouchesInView = true
                recognizer.delegate = coordinator
                addGestureRecognizer(recognizer)
                taskMarkerTapGesture = recognizer
            }
        }
    }

    extension MarkdownTextView {
        func taskMarkerOffset(at point: CGPoint) -> Int? {
            guard let position = closestPosition(to: point) else {
                return nil
            }
            let offset = self.offset(from: beginningOfDocument, to: position)
            guard let range = editingSession.taskItemProjectionRange(containing: offset),
                  let start = self.position(from: beginningOfDocument, offset: range.location) else {
                return nil
            }
            let caret = caretRect(for: start)
            let markerBounds = MarkdownTaskCheckboxLayer.hitBounds(textRect: caret, theme: editingSession.theme)
            return markerBounds.contains(point) ? range.location : nil
        }
    }

    /// An invisible view over one drawn task checkbox that VoiceOver reads as a button toggling its task.
    ///
    /// It ignores touches, so taps still reach the text view's task-marker gesture.
    @MainActor final class MarkdownTaskCheckboxAccessibilityView: UIView {
        private weak var textView: MarkdownTextView?
        /// The projected offset of the task item's first leaf.
        private var offset = 0

        init(textView: MarkdownTextView) {
            self.textView = textView
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityTraits = .button
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        func update(offset: Int, checked: Bool, frame: CGRect) {
            self.offset = offset
            self.frame = frame
            accessibilityValue = checked ? "Checked" : "Unchecked"
        }

        override var accessibilityLabel: String? {
            get { textView?.editingSession.taskCheckboxLabel(atProjectionUTF16Offset: offset) }
            set {}
        }

        override func accessibilityActivate() -> Bool {
            textView?.editingSession.toggleTask(atProjectionUTF16Offset: offset) ?? false
        }
    }

    @MainActor private final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        /// The text view whose callbacks this coordinator forwards.
        private weak var owner: MarkdownTextView?

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

        func textViewDidChange(_ textView: UITextView) {
            owner?.textDidChange()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            owner?.selectionDidChange()
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard owner?.isHandlingNativeInput != true, textView.markedTextRange == nil else {
                return true
            }
            return owner?.editingSession.shouldReplaceCharacters(in: range, with: text) ?? true
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            owner?.nativeEditMenu(forTextIn: range, suggestedActions: suggestedActions)
        }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard let owner, case let .link(url) = textItem.content,
                  owner.editingSession.headingProjectionRange(forLinkDestination: url.relativeString) != nil else {
                return defaultAction
            }
            return UIAction { [weak owner] _ in
                owner?.scrollToHeading(linkDestination: url.relativeString)
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard let owner else {
                return false
            }
            return owner.taskMarkerOffset(at: touch.location(in: owner)) != nil
        }
    }
#endif
