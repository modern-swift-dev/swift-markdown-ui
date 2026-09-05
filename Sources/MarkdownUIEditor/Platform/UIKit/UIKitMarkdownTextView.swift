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
    /// Avoids recording the same edit again if UIKit also calls its delegate.
    fileprivate var isHandlingNativeInput = false

    override public func layoutSubviews() {
        super.layoutSubviews()
        guard hasAttachedEditingSession else {
            return
        }
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
            guard offset < textStorage.length,
                  let checked = textStorage.attribute(.markdownEditorTaskChecked, at: offset, effectiveRange: nil) as? NSNumber,
                  let position = position(from: beginningOfDocument, offset: offset) else {
                continue
            }
            if count == taskCheckboxLayers.count {
                let checkbox = MarkdownTaskCheckboxLayer()
                layer.addSublayer(checkbox)
                taskCheckboxLayers.append(checkbox)
            }
            taskCheckboxLayers[count].update(textRect: caretRect(for: position), checked: checked.boolValue, color: UIColor.label.resolvedColor(with: traitCollection).cgColor, theme: editorTheme)
            count += 1
        }
        while taskCheckboxLayers.count > count {
            taskCheckboxLayers.removeLast().removeFromSuperlayer()
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
            )
        ]
    }

    override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
            case #selector(toggleStrong):
                canPerform(.toggleInline(.strong))
            case #selector(toggleEmphasis):
                canPerform(.toggleInline(.emphasis))
            case #selector(toggleStrikethrough):
                canPerform(.toggleInline(.strikethrough))
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

private extension MarkdownTextView {
    func attachEditingSessionIfNeeded() {
        assert(textLayoutManager != nil)
        assert(textContainer.textLayoutManager != nil)

        guard !hasAttachedEditingSession else {
            return
        }
        super.delegate = coordinator
        coordinator.observeUndoManager(undoManager)
        editingSession.attach(to: self)
        hasAttachedEditingSession = true
    }

    func configureNativeEditing() {
        adjustsFontForContentSizeCategory = true

        let bold = UIBarButtonItem(title: "B", style: .plain, target: self, action: #selector(toggleStrong))
        let italic = UIBarButtonItem(title: "I", style: .plain, target: self, action: #selector(toggleEmphasis))
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

    internal func taskMarkerOffset(at point: CGPoint) -> Int? {
        guard let position = closestPosition(to: point) else {
            return nil
        }
        let offset = self.offset(from: beginningOfDocument, to: position)
        guard let range = editingSession.taskItemProjectionRange(containing: offset),
              let start = self.position(from: beginningOfDocument, offset: range.location) else {
            return nil
        }
        let caret = caretRect(for: start)
        let markerBounds = MarkdownTaskCheckboxLayer.hitBounds(textRect: caret, theme: editorTheme)
        return markerBounds.contains(point) ? range.location : nil
    }
}

@MainActor private final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
    /// The text view whose callbacks this coordinator forwards.
    private weak var owner: MarkdownTextView?

    init(owner: MarkdownTextView) {
        self.owner = owner
    }

    func observeUndoManager(_ undoManager: UndoManager?) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(undoManagerDidChange(_:)),
            name: .NSUndoManagerDidUndoChange,
            object: undoManager
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(undoManagerDidChange(_:)),
            name: .NSUndoManagerDidRedoChange,
            object: undoManager
        )
    }

    @objc private func undoManagerDidChange(_ notification: Notification) {
        owner?.editingSession.undoManagerDidChange()
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
