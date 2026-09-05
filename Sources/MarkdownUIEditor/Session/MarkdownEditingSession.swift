import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit) || canImport(AppKit)
private struct PendingNativeEdit {
    var path: EditorNodePath
    var unitRange: NSRange
    var projectionDelta: Int
}

private struct ActiveTableSelection: Equatable, Sendable {
    var path: EditorNodePath
    var cell: MarkdownTableCellSelection
}

/// Coordinates the typed Markdown model with one platform-native TextKit view.
///
/// The session owns semantic reconciliation, projection mappings, and undo
/// snapshots. Platform views only forward storage and selection notifications.
@MainActor final class MarkdownEditingSession {
    /// Last committed structured Markdown document.
    private(set) var document: MarkdownDocument
    /// Native projection and source mappings. Built lazily when a bridge attaches.
    private(set) lazy var projection: DocumentProjection = makeProjection(document: document)
    /// Attributes used when building or refreshing the projection.
    private(set) var theme: MarkdownEditorTheme
    /// Base URL used by URL-backed image attachments.
    private(set) var baseURL: URL?
    /// Provider used by URL-backed image attachments.
    private(set) var imageProvider: (any MarkdownEditorImageProvider)?

    /// Platform adapter that owns TextKit storage and native selection.
    private weak var bridge: (any TextViewBridge)?
    /// Delivers committed document changes to the owning text view.
    private let onDocumentChange: (MarkdownDocument) -> Void
    /// Suppresses delayed binding echoes of documents the session recently published.
    private var pendingLocalEchoes: [MarkdownDocument] = []
    /// Prevents bridge callbacks from treating projection installation as user input.
    private var isUpdatingBridge = false
    /// Defers parsing until an IME composition completes.
    private var needsCompositionFlush = false
    /// Native edit captured before TextKit mutates the attributed storage.
    private var pendingNativeEdits: [PendingNativeEdit] = []
    /// Nested table selection that currently owns keyboard focus.
    private var activeTableSelection: ActiveTableSelection?
    private var restoredSnapshotSinceUndoNotification = false

    var onCommandStateChange: (() -> Void)?

    var hasActiveTableSelection: Bool {
        activeTableSelection != nil
    }

    private static func editableDocument(_ document: MarkdownDocument) -> MarkdownDocument {
        document.blocks.isEmpty ? MarkdownDocument(blocks: [.paragraph([])]) : document
    }

    /// Creates a session with document state and projection configuration.
    init(
        document: MarkdownDocument,
        theme: MarkdownEditorTheme = .basic,
        baseURL: URL? = nil,
        imageProvider: (any MarkdownEditorImageProvider)? = nil,
        onDocumentChange: @escaping (MarkdownDocument) -> Void = { _ in }
    ) {
        self.document = Self.editableDocument(document)
        self.theme = theme
        self.baseURL = baseURL
        self.imageProvider = imageProvider
        self.onDocumentChange = onDocumentChange
    }

    /// Attaches the session to a native text view and installs its first projection.
    func attach(to bridge: any TextViewBridge) {
        self.bridge = bridge
        installProjection(projection, selectedRanges: bridge.markdownSelectedRanges)
    }

    /// Records a native edit before TextKit mutates storage.
    ///
    /// Structural edits are intercepted here. Ordinary text edits proceed and
    /// are reconciled from the attributed leaf in `storageDidChange()`.
    func shouldReplaceCharacters(in range: NSRange, with replacement: String) -> Bool {
        guard !isUpdatingBridge,
              let downstreamUnit = projection.index.unit(
                  atProjectionUTF16Offset: min(range.location, projection.index.projectionUTF16Length)
              ) else {
            return true
        }
        let unit: ProjectionUnit = if replacement == "\n",
                                      range.length == 0,
                                      range.location == downstreamUnit.projectionRange.location,
                                      let precedingUnit = projection.index.unit(
                                          atProjectionUTF16Offset: range.location,
                                          affinity: .upstream
                                      ),
                                      precedingUnit.path.components.count == 3,
                                      downstreamUnit.path.components.count == 3,
                                      case .listItem = precedingUnit.path.components[1],
                                      case .listItem = downstreamUnit.path.components[1],
                                      precedingUnit.path.components.first != downstreamUnit.path.components.first {
            precedingUnit
        } else {
            downstreamUnit
        }
        guard NSMaxRange(range) <= unit.projectionRange.upperBound else {
            return !replaceProjectedRange(range, with: attributedInsertion(replacement))
        }
        if unit.kind == .table,
           !replacement.isEmpty,
           range.length == 0,
           range.location == unit.projectionRange.upperBound,
           handleInsertionAfterTable(replacement, at: unit.path) {
            return false
        }
        if replacement == "\n", unit.kind != .codeBlock, handleReturn(in: unit, replacing: range) {
            return false
        }
        if replacement.isEmpty,
           range.length == 1,
           range.location == unit.projectionRange.upperBound - 1,
           handleBackwardBoundaryDeletion(after: unit) {
            return false
        }
        if range.location == projection.index.projectionUTF16Length, range.length == 0 {
            let end = NSRange(location: max(0, range.location - 1), length: 0)
            return !replaceProjectedRange(end, with: attributedInsertion(replacement))
        }
        if range.length > 0, NSMaxRange(range) == unit.projectionRange.upperBound {
            return !replaceProjectedRange(range, with: attributedInsertion(replacement))
        }
        pendingNativeEdits = [PendingNativeEdit(
            path: unit.path,
            unitRange: unit.projectionRange.nsRange,
            projectionDelta: replacement.utf16.count - range.length
        )]
        return true
    }

    /// Records an AppKit multi-selection edit without collapsing its ranges.
    func shouldReplaceCharacters(in ranges: [NSRange], with replacements: [String]) -> Bool {
        guard ranges.count == replacements.count, ranges.count > 1 else {
            return true
        }
        var edits: [EditorNodePath: PendingNativeEdit] = [:]
        for (range, replacement) in zip(ranges, replacements) {
            guard replacement != "\n",
                  let unit = projection.index.unit(atProjectionUTF16Offset: range.location),
                  NSMaxRange(range) <= unit.projectionRange.upperBound - 1 else {
                return true
            }
            let delta = replacement.utf16.count - range.length
            if var edit = edits[unit.path] {
                edit.projectionDelta += delta
                edits[unit.path] = edit
            } else {
                edits[unit.path] = PendingNativeEdit(
                    path: unit.path,
                    unitRange: unit.projectionRange.nsRange,
                    projectionDelta: delta
                )
            }
        }
        // TextKit has applied every range before storageDidChange arrives.
        // Reconcile each leaf using its total length change.
        pendingNativeEdits = edits.values.sorted { $0.unitRange.location < $1.unitRange.location }
        return true
    }

    /// Acknowledges a value read back from a binding after publication.
    /// Once acknowledged, the same value can later be restored intentionally.
    @discardableResult func acknowledgeBindingDocument(_ value: MarkdownDocument) -> Bool {
        guard let echoIndex = pendingLocalEchoes.lastIndex(where: {
            value == $0 || value == MarkdownDocument(markdown: $0.markdown)
        }) else {
            return false
        }
        pendingLocalEchoes.removeFirst(echoIndex + 1)
        return true
    }

    /// Synchronizes a binding without letting delayed echoes overwrite newer edits.
    func replaceDocumentFromBinding(_ replacement: MarkdownDocument) {
        guard !acknowledgeBindingDocument(replacement) else {
            return
        }
        replaceDocument(replacement)
    }

    /// Replaces the document from an external owner, preserving selection where possible.
    func replaceDocument(_ replacement: MarkdownDocument) {
        pendingLocalEchoes.removeAll()

        guard Self.editableDocument(replacement) != document else {
            return
        }
        needsCompositionFlush = false
        pendingNativeEdits = []
        document = Self.editableDocument(replacement)
        activeTableSelection = validated(activeTableSelection, in: replacement)
        projection = makeProjection(document: document)
        installProjection(projection, selectedRanges: restoredRanges(bridge?.markdownSelectedRanges ?? [], in: projection))
    }

    /// Rebuilds the projection with a new attribute theme.
    func replaceTheme(_ replacement: MarkdownEditorTheme) {
        guard theme !== replacement,
              !themesAreEqual(theme, replacement) else {
            return
        }
        theme = replacement
        projection = makeProjection(document: document)
        installProjection(projection, selectedRanges: bridge?.markdownSelectedRanges ?? [])
    }

    func replaceObjectConfiguration(
        baseURL: URL?,
        imageProvider: (any MarkdownEditorImageProvider)?
    ) {
        guard self.baseURL != baseURL || !sameImageProvider(self.imageProvider, imageProvider) else {
            return
        }
        self.baseURL = baseURL
        self.imageProvider = imageProvider
        projection = makeProjection(document: document)
        installProjection(projection, selectedRanges: bridge?.markdownSelectedRanges ?? [])
    }

    /// Updates native typing attributes for the semantic run at the caret.
    func selectionDidChange() {
        defer {
            if !isUpdatingBridge {
                onCommandStateChange?()
            }
        }
        guard !isUpdatingBridge, let bridge, !bridge.markdownHasMarkedText,
              let selection = bridge.markdownSelectedRanges.first else {
            return
        }
        if bridge.markdownIsFirstResponder {
            activeTableSelection = nil
        }
        guard selection.length == 0 else {
            return
        }
        bridge.markdownTypingAttributes = typingAttributes(at: selection.location, in: bridge.markdownTextStorage)
    }

    /// Reconciles a user edit unless the platform is composing marked text.
    func storageDidChange() {
        guard !isUpdatingBridge, let bridge else {
            return
        }
        if bridge.markdownHasMarkedText {
            needsCompositionFlush = true
            return
        }
        reconcileRichStorageChange()
    }

    /// Snapshot restoration has already updated both model and storage. Native text
    /// undo still needs reconciliation, but rebuilding a restored attachment again
    /// would disturb its focus and the platform redo stack.
    func undoManagerDidChange() {
        if restoredSnapshotSinceUndoNotification {
            restoredSnapshotSinceUndoNotification = false
            return
        }
        storageDidChange()
    }

    /// Flushes a deferred IME edit with the structural fallback enabled.
    func compositionDidEnd() {
        guard needsCompositionFlush else {
            return
        }
        needsCompositionFlush = false
        reconcileRichStorageChange()
    }

    /// Applies a structural command and registers the result as one undo operation.
    func perform(_ command: MarkdownEditorCommand) {
        defer { onCommandStateChange?() }
        guard let bridge, let nativeSelection = bridge.markdownSelectedRanges.first else {
            return
        }
        if let active = activeTableSelection, active.cell.range.length == 0,
           updateTableTypingAttributes(for: command) {
            return
        }
        if activeTableSelection == nil, nativeSelection.length > 0,
           performAcrossBlocks(command, selection: nativeSelection) {
            return
        }
        if activeTableSelection == nil,
           nativeSelection.length == 0,
           updateTypingAttributes(for: command, bridge: bridge) {
            return
        }
        guard let logicalSelection = activeTableSelection.flatMap({ logicalSelection(for: $0) })
            ?? logicalSelection(for: nativeSelection) else {
            return
        }

        let before = Snapshot(
            document: document,
            selectedRanges: bridge.markdownSelectedRanges,
            typingAttributes: bridge.markdownTypingAttributes,
            tableSelection: activeTableSelection
        )
        let result = MarkdownEditingEngine.apply(command, to: document, selection: logicalSelection)
        guard result.document != document else {
            return
        }

        document = result.document
        activeTableSelection = tableSelection(for: result.selection)
        pendingNativeEdits = []
        projection = makeProjection(document: document)
        let selection = projectionRange(for: result.selection) ?? nativeSelection
        installProjection(projection, selectedRanges: [selection])
        publishDocumentChange()

        let after = Snapshot(
            document: document,
            selectedRanges: bridge.markdownSelectedRanges,
            typingAttributes: bridge.markdownTypingAttributes,
            tableSelection: activeTableSelection
        )
        registerUndo(from: after, to: before)
    }

    /// Toggles the task item containing a projected text position.
    ///
    /// Marker hit testing is platform-specific, but the semantic lookup and
    /// document mutation belong here so taps and clicks use normal undo and
    /// change publication.
    @discardableResult func toggleTask(atProjectionUTF16Offset offset: Int) -> Bool {
        guard let bridge,
              offset >= 0,
              offset <= projection.index.projectionUTF16Length,
              let selection = logicalSelection(for: NSRange(location: offset, length: 0)) else {
            return false
        }
        let result = MarkdownEditingEngine.apply(.toggleTask, to: document, selection: selection)
        guard result.document != document else {
            return false
        }

        let before = Snapshot(
            document: document,
            selectedRanges: bridge.markdownSelectedRanges,
            typingAttributes: bridge.markdownTypingAttributes,
            tableSelection: activeTableSelection
        )
        document = result.document
        pendingNativeEdits = []
        projection = makeProjection(document: document)
        installProjection(projection, selectedRanges: before.selectedRanges)
        publishDocumentChange()
        let after = Snapshot(
            document: document,
            selectedRanges: bridge.markdownSelectedRanges,
            typingAttributes: bridge.markdownTypingAttributes,
            tableSelection: activeTableSelection
        )
        registerUndo(from: after, to: before)
        return true
    }

    /// Returns the projected leaf range when the position belongs to a task item.
    func taskItemProjectionRange(containing offset: Int) -> NSRange? {
        guard offset >= 0,
              offset <= projection.index.projectionUTF16Length,
              let unit = projection.index.unit(atProjectionUTF16Offset: offset),
              let selection = logicalSelection(for: NSRange(location: offset, length: 0)),
              MarkdownEditingEngine.apply(.toggleTask, to: document, selection: selection).document != document else {
            return nil
        }
        return unit.projectionRange.nsRange
    }

    /// Builds Markdown and plain-text clipboard representations for the selection.
    func clipboardPayload() -> MarkdownClipboardPayload? {
        guard let bridge, let range = bridge.markdownSelectedRanges.first,
              range.length > 0,
              NSMaxRange(range) <= bridge.markdownTextStorage.length else {
            return nil
        }
        let fragment = selectedDocument(in: range)
        let serialized = fragment.markdown
        let markdown = serialized.hasSuffix("\n") ? String(serialized.dropLast()) : serialized
        return MarkdownClipboardPayload(
            markdown: markdown,
            plainText: (bridge.markdownTextStorage.string as NSString).substring(with: range)
        )
    }

    /// Inserts a parsed Markdown inline fragment or literal plain text.
    @discardableResult func paste(_ payload: MarkdownClipboardPayload) -> Bool {
        guard let bridge, let range = bridge.markdownSelectedRanges.first else {
            return false
        }
        let insertion: NSAttributedString
        if let markdown = payload.markdown {
            let parsed = MarkdownDocument(markdown: markdown)
            if parsed.blocks.count != 1 || !isParagraph(parsed.blocks[0]) {
                return pasteBlockFragment(parsed, replacing: range)
            }
            let projected = makeProjection(document: parsed).attributedString
            let length = max(0, projected.length - 1)
            insertion = projected.attributedSubstring(from: NSRange(location: 0, length: length))
        } else if let plainText = payload.plainText {
            insertion = NSAttributedString(
                string: plainText,
                attributes: bridge.markdownTypingAttributes.isEmpty
                    ? theme.bodyAttributes
                    : bridge.markdownTypingAttributes
            )
        } else {
            return false
        }
        let before = Snapshot(
            document: document,
            selectedRanges: bridge.markdownSelectedRanges,
            typingAttributes: bridge.markdownTypingAttributes,
            tableSelection: activeTableSelection
        )
        if let unit = projection.index.unit(atProjectionUTF16Offset: range.location),
           NSMaxRange(range) > unit.projectionRange.upperBound || range.location == projection.index.projectionUTF16Length {
            let effective = range.location == projection.index.projectionUTF16Length
                ? NSRange(location: max(0, range.location - 1), length: range.length) : range
            return replaceProjectedRange(effective, with: insertion)
        }
        guard shouldReplaceCharacters(in: range, with: insertion.string) else {
            return true
        }
        bridge.replaceAttributedCharacters(
            in: range,
            with: insertion
        )
        bridge.markdownSelectedRanges = [
            NSRange(location: range.location + insertion.length, length: 0)
        ]
        storageDidChange()
        let after = Snapshot(
            document: document,
            selectedRanges: bridge.markdownSelectedRanges,
            typingAttributes: bridge.markdownTypingAttributes,
            tableSelection: activeTableSelection
        )
        if after.document != before.document {
            registerUndo(from: after, to: before)
        }
        return true
    }
}

private extension MarkdownEditingSession {
    /// Document and native selections captured for an undo operation.
    struct Snapshot {
        /// Structured state to restore.
        var document: MarkdownDocument
        /// Projection ranges to restore after rebuilding.
        var selectedRanges: [NSRange]
        /// Collapsed-caret semantic and visual typing state.
        var typingAttributes: [NSAttributedString.Key: Any]
        /// Nested cell focus to restore with the document projection.
        var tableSelection: ActiveTableSelection?

        init(
            document: MarkdownDocument,
            selectedRanges: [NSRange],
            typingAttributes: [NSAttributedString.Key: Any],
            tableSelection: ActiveTableSelection? = nil
        ) {
            self.document = document
            self.selectedRanges = selectedRanges
            self.typingAttributes = typingAttributes
            self.tableSelection = tableSelection
        }
    }

    /// Builds a full projection and wires object attachment changes back to this session.
    func makeProjection(document: MarkdownDocument) -> DocumentProjection {
        MarkdownProjectionBuilder().build(
            document: document,
            theme: theme,
            baseURL: baseURL,
            imageProvider: imageProvider,
            onTableChange: { [weak self] path, table in
                self?.replaceTable(at: path, with: table)
            },
            tableSelection: { [weak self] path in
                guard self?.activeTableSelection?.path == path else {
                    return nil
                }
                return self?.activeTableSelection?.cell
            },
            onTableSelectionChange: { [weak self] path, selection in
                self?.tableSelectionDidChange(at: path, selection: selection)
            },
            onImageChange: { [weak self] path, metadata in
                self?.replaceImage(at: path, with: metadata)
            }
        )
    }

    func tableSelectionDidChange(
        at path: EditorNodePath,
        selection: MarkdownTableCellSelection?
    ) {
        guard !isUpdatingBridge else {
            return
        }
        activeTableSelection = selection.map { ActiveTableSelection(path: path, cell: $0) }
        onCommandStateChange?()
        guard selection != nil, let bridge,
              let unit = projection.index.unit(at: path) else {
            return
        }
        isUpdatingBridge = true
        bridge.markdownSelectedRanges = [
            NSRange(location: unit.projectionRange.location, length: 0)
        ]
        isUpdatingBridge = false
    }

    func logicalSelection(for active: ActiveTableSelection) -> MarkdownLogicalSelection? {
        guard let tablePath = logicalPath(for: active.path) else {
            return nil
        }
        let row = switch active.cell.position.section {
            case .header: 0
            case let .body(row): row + 1
        }
        return MarkdownLogicalSelection(
            path: .tableCell(table: tablePath, row: row, column: active.cell.position.column),
            utf16Offset: active.cell.range.location,
            utf16Length: active.cell.range.length
        )
    }

    func tableSelection(for logical: MarkdownLogicalSelection) -> ActiveTableSelection? {
        guard case let .tableCell(tablePath, row, column) = logical.path else {
            return nil
        }
        let section: MarkdownTableCellPosition.Section = row == 0 ? .header : .body(row: row - 1)
        return ActiveTableSelection(
            path: editorPath(for: tablePath),
            cell: MarkdownTableCellSelection(
                position: MarkdownTableCellPosition(section: section, column: column),
                range: NSRange(location: logical.utf16Offset, length: logical.utf16Length)
            )
        )
    }

    func validated(
        _ active: ActiveTableSelection?,
        in document: MarkdownDocument
    ) -> ActiveTableSelection? {
        guard let active,
              case let .table(table)? = leafBlock(at: active.path, in: document) else {
            return nil
        }
        let hasCell = switch active.cell.position.section {
            case .header:
                table.header.cells.indices.contains(active.cell.position.column)
            case let .body(row):
                table.rows.indices.contains(row)
                    && table.rows[row].cells.indices.contains(active.cell.position.column)
        }
        return hasCell ? active : nil
    }

    func sameImageProvider(
        _ first: (any MarkdownEditorImageProvider)?,
        _ second: (any MarkdownEditorImageProvider)?
    ) -> Bool {
        switch (first, second) {
            case (nil, nil):
                true
            case let (first?, second?):
                first === second
            default:
                false
        }
    }

    func replaceTable(at path: EditorNodePath, with table: MarkdownTable) {
        guard let replacement = replacingBlock(at: path, with: .table(table)) else {
            return
        }
        applyTableReplacement(replacement)
    }

    func replaceImage(at path: EditorNodePath, with metadata: MarkdownImageMetadata) {
        guard case let .block(rootIndex)? = path.components.first,
              document.blocks.indices.contains(rootIndex),
              let block = replacingImage(
                  in: document.blocks[rootIndex],
                  components: Array(path.components.dropFirst()),
                  metadata: metadata
              ) else {
            return
        }
        var replacement = document
        replacement.blocks[rootIndex] = block
        applyObjectReplacement(replacement)
    }

    func replacingBlock(at path: EditorNodePath, with replacement: MarkdownBlock) -> MarkdownDocument? {
        guard case let .block(rootIndex)? = path.components.first,
              document.blocks.indices.contains(rootIndex) else {
            return nil
        }
        var updated = document
        let remaining = Array(path.components.dropFirst())
        if remaining.isEmpty {
            updated.blocks[rootIndex] = replacement
        } else {
            guard let root = replacingNestedLeaf(
                in: updated.blocks[rootIndex],
                components: remaining,
                with: replacement
            ) else {
                return nil
            }
            updated.blocks[rootIndex] = root
        }
        return updated
    }

    func applyObjectReplacement(_ replacement: MarkdownDocument) {
        guard replacement != document else {
            return
        }
        let ranges = bridge?.markdownSelectedRanges ?? []
        let before = Snapshot(
            document: document,
            selectedRanges: ranges,
            typingAttributes: bridge?.markdownTypingAttributes ?? [:],
            tableSelection: activeTableSelection
        )
        document = replacement
        pendingNativeEdits = []
        projection = makeProjection(document: replacement)
        installProjection(projection, selectedRanges: ranges)
        publishDocumentChange()
        let after = Snapshot(
            document: document,
            selectedRanges: bridge?.markdownSelectedRanges ?? ranges,
            typingAttributes: bridge?.markdownTypingAttributes ?? [:],
            tableSelection: activeTableSelection
        )
        registerUndo(from: after, to: before)
    }

    func applyTableReplacement(_ replacement: MarkdownDocument) {
        guard replacement != document else {
            return
        }
        let ranges = bridge?.markdownSelectedRanges ?? []
        let before = Snapshot(
            document: document,
            selectedRanges: ranges,
            typingAttributes: bridge?.markdownTypingAttributes ?? [:],
            tableSelection: activeTableSelection
        )
        document = replacement
        pendingNativeEdits = []
        var replacementProjection = makeProjection(document: replacement)
        replacementProjection.attributedString = projection.attributedString
        projection = replacementProjection
        publishDocumentChange()
        let after = Snapshot(
            document: document,
            selectedRanges: bridge?.markdownSelectedRanges ?? ranges,
            typingAttributes: bridge?.markdownTypingAttributes ?? [:],
            tableSelection: activeTableSelection
        )
        registerUndo(from: after, to: before)
    }

    func reconcileRichStorageChange() {
        guard let bridge else {
            return
        }

        let edits = pendingNativeEdits
        pendingNativeEdits = []
        if !edits.isEmpty {
            for edit in edits {
                reconcileRichEdit(edit, bridge: bridge)
            }
            selectionDidChange()
            return
        }
        let selectedOffset = bridge.markdownSelectedRanges.first?.location ?? 0
        let lookupOffset = min(
            max(0, selectedOffset),
            projection.index.projectionUTF16Length
        )
        guard let path = projection.index.unit(atProjectionUTF16Offset: lookupOffset)?.path,
              let oldUnit = projection.index.unit(at: path) else {
            rebuildAfterUnsafeNativeEdit(selectedRanges: bridge.markdownSelectedRanges)
            return
        }

        let totalDelta = bridge.markdownTextStorage.length - projection.index.projectionUTF16Length
        let unitLength = oldUnit.projectionRange.length + totalDelta
        guard unitLength > 0 else {
            rebuildAfterUnsafeNativeEdit(selectedRanges: bridge.markdownSelectedRanges)
            return
        }
        let contentRange = NSRange(
            location: oldUnit.projectionRange.location,
            length: unitLength - 1
        )
        guard NSMaxRange(contentRange) <= bridge.markdownTextStorage.length else {
            rebuildAfterUnsafeNativeEdit(selectedRanges: bridge.markdownSelectedRanges)
            return
        }

        let attributedContent = bridge.markdownTextStorage.attributedSubstring(from: contentRange)
        guard let currentBlock = leafBlock(at: path),
              let replacementBlock = replacingRichContent(in: currentBlock, with: attributedContent),
              let replacement = replacingBlock(at: path, with: replacementBlock) else {
            rebuildAfterUnsafeNativeEdit(selectedRanges: bridge.markdownSelectedRanges)
            return
        }

        guard projection.reconcileRichLeaf(
            at: path,
            textStorage: bridge.markdownTextStorage,
            projectionLength: unitLength,
            kind: projectionKind(at: path, in: replacement)
        ) else {
            document = replacement
            rebuildAfterUnsafeNativeEdit(selectedRanges: bridge.markdownSelectedRanges)
            publishDocumentChange()
            return
        }

        if replacement != document {
            document = replacement
            publishDocumentChange()
        }
        selectionDidChange()
    }

    func reconcileRichEdit(_ edit: PendingNativeEdit, bridge: any TextViewBridge) {
        guard let oldUnit = projection.index.unit(at: edit.path) else {
            rebuildAfterUnsafeNativeEdit(selectedRanges: bridge.markdownSelectedRanges)
            return
        }
        let unitLength = oldUnit.projectionRange.length + edit.projectionDelta
        let contentRange = NSRange(
            location: oldUnit.projectionRange.location,
            length: max(0, unitLength - 1)
        )
        guard unitLength > 0,
              NSMaxRange(contentRange) <= bridge.markdownTextStorage.length,
              let currentBlock = leafBlock(at: edit.path) else {
            rebuildAfterUnsafeNativeEdit(selectedRanges: bridge.markdownSelectedRanges)
            return
        }
        let attributedContent = bridge.markdownTextStorage.attributedSubstring(from: contentRange)
        guard let replacementBlock = replacingRichContent(in: currentBlock, with: attributedContent),
              let replacement = replacingBlock(at: edit.path, with: replacementBlock),
              projection.reconcileRichLeaf(
                  at: edit.path,
                  textStorage: bridge.markdownTextStorage,
                  projectionLength: unitLength,
                  kind: projectionKind(at: edit.path, in: replacement)
              ) else {
            rebuildAfterUnsafeNativeEdit(selectedRanges: bridge.markdownSelectedRanges)
            return
        }
        if replacement != document {
            document = replacement
            publishDocumentChange()
        }
    }

    func replacingRichContent(
        in block: MarkdownBlock,
        with attributedContent: NSAttributedString
    ) -> MarkdownBlock? {
        switch block {
            case .paragraph:
                .paragraph(MarkdownAttributedInlineDecoder.decode(attributedContent))
            case let .heading(level, _):
                .heading(level: level, content: MarkdownAttributedInlineDecoder.decode(attributedContent))
            case let .codeBlock(info, _):
                .codeBlock(info: info, content: attributedContent.string)
            case .html:
                .html(attributedContent.string)
            case .blockquote,
                 .list,
                 .table,
                 .thematicBreak:
                nil
        }
    }

    func rebuildAfterUnsafeNativeEdit(selectedRanges: [NSRange]) {
        projection = makeProjection(document: document)
        installProjection(projection, selectedRanges: selectedRanges)
    }

    func typingAttributes(
        at offset: Int,
        in textStorage: NSTextStorage
    ) -> [NSAttributedString.Key: Any] {
        guard textStorage.length > 0 else {
            return theme.bodyAttributes
        }
        let clampedOffset = min(max(0, offset), textStorage.length)
        let unitStart = projection.index.unit(atProjectionUTF16Offset: clampedOffset)?.projectionRange.location
        let index = if clampedOffset > 0, clampedOffset != unitStart {
            clampedOffset - 1
        } else {
            min(clampedOffset, textStorage.length - 1)
        }
        var attributes = textStorage.attributes(at: index, effectiveRange: nil)
        attributes.removeValue(forKey: .attachment)
        attributes.removeValue(forKey: .markdownEditorNodeID)
        attributes.removeValue(forKey: .markdownEditorNodePath)
        attributes.removeValue(forKey: .markdownEditorObjectKind)
        return attributes
    }

    func updateTypingAttributes(
        for command: MarkdownEditorCommand,
        bridge: any TextViewBridge
    ) -> Bool {
        var attributes = bridge.markdownTypingAttributes
        switch command {
            case let .toggleInline(style):
                let key: NSAttributedString.Key = switch style {
                    case .strong: .markdownEditorStrong
                    case .emphasis: .markdownEditorEmphasis
                    case .strikethrough: .markdownEditorStrikethrough
                    case .code: .markdownEditorCode
                }
                let wasEnabled = (attributes[key] as? NSNumber)?.boolValue == true
                    || (attributes[key] as? Bool) == true
                if wasEnabled {
                    attributes.removeValue(forKey: key)
                } else {
                    if style == .code {
                        removeNonCodeInlineSemantics(from: &attributes)
                        attributes.merge(theme.codeAttributes) { _, replacement in replacement }
                    }
                    attributes[key] = true
                }
                applyVisualTypingStyle(
                    style,
                    enabled: !wasEnabled,
                    to: &attributes,
                    bridge: bridge
                )
            case let .setLink(destination, title):
                attributes[.markdownEditorLinkDestination] = destination
                attributes[.link] = destination
                if let title {
                    attributes[.markdownEditorLinkTitle] = title
                } else {
                    attributes.removeValue(forKey: .markdownEditorLinkTitle)
                }
                attributes.merge(theme.linkAttributes) { _, replacement in replacement }
            case .removeLink:
                attributes.removeValue(forKey: .markdownEditorLinkDestination)
                attributes.removeValue(forKey: .markdownEditorLinkTitle)
                attributes.removeValue(forKey: .link)
            default:
                return false
        }
        bridge.markdownTypingAttributes = attributes
        return true
    }

    func removeNonCodeInlineSemantics(
        from attributes: inout [NSAttributedString.Key: Any]
    ) {
        attributes.removeValue(forKey: .markdownEditorStrong)
        attributes.removeValue(forKey: .markdownEditorEmphasis)
        attributes.removeValue(forKey: .markdownEditorStrikethrough)
        attributes.removeValue(forKey: .markdownEditorLinkDestination)
        attributes.removeValue(forKey: .markdownEditorLinkTitle)
        attributes.removeValue(forKey: .link)
    }

    func applyVisualTypingStyle(
        _ style: MarkdownInlineStyle,
        enabled: Bool,
        to attributes: inout [NSAttributedString.Key: Any],
        bridge: any TextViewBridge
    ) {
        switch style {
            case .strikethrough:
                if enabled || (attributes[.markdownEditorTaskChecked] as? NSNumber)?.boolValue == true {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                } else {
                    attributes.removeValue(forKey: .strikethroughStyle)
                }
            case .code:
                if enabled {
                    attributes.merge(theme.codeAttributes) { _, replacement in replacement }
                } else {
                    let offset = bridge.markdownSelectedRanges.first?.location ?? 0
                    let base = projection.index.unit(atProjectionUTF16Offset: offset).flatMap { unit in
                        if case let .heading(level) = unit.kind {
                            return theme.headingAttributes[level]
                        }
                        return theme.bodyAttributes
                    } ?? theme.bodyAttributes
                    attributes.merge(base) { _, replacement in replacement }
                }
            case .strong,
                 .emphasis:
                #if canImport(UIKit)
                guard let font = attributes[.font] as? UIFont else {
                    return
                }
                var traits = font.fontDescriptor.symbolicTraits
                let trait: UIFontDescriptor.SymbolicTraits = style == .strong ? .traitBold : .traitItalic
                if enabled {
                    traits.insert(trait)
                } else {
                    traits.remove(trait)
                }
                if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                    attributes[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
                }
                #elseif canImport(AppKit)
                guard let font = attributes[.font] as? NSFont else {
                    return
                }
                let trait: NSFontTraitMask = style == .strong ? .boldFontMask : .italicFontMask
                attributes[.font] = enabled
                    ? NSFontManager.shared.convert(font, toHaveTrait: trait)
                    : NSFontManager.shared.convert(font, toNotHaveTrait: trait)
                #endif
        }
    }

    func handleReturn(in unit: ProjectionUnit, replacing range: NSRange) -> Bool {
        let effectiveRange: NSRange = if range.length == 0,
                                         range.location == unit.projectionRange.upperBound {
            NSRange(location: range.location - 1, length: 0)
        } else {
            range
        }
        guard let bridge,
              effectiveRange.location >= unit.projectionRange.location,
              NSMaxRange(effectiveRange) <= unit.projectionRange.upperBound - 1 else {
            return false
        }
        let localRange = NSRange(
            location: effectiveRange.location - unit.projectionRange.location,
            length: effectiveRange.length
        )
        let contentLength = unit.projectionRange.length - 1
        let beforeRange = NSRange(location: unit.projectionRange.location, length: localRange.location)
        let afterRange = NSRange(
            location: NSMaxRange(effectiveRange),
            length: contentLength - NSMaxRange(localRange)
        )
        let before = MarkdownAttributedInlineDecoder.decode(
            bridge.markdownTextStorage.attributedSubstring(from: beforeRange)
        )
        let after = MarkdownAttributedInlineDecoder.decode(
            bridge.markdownTextStorage.attributedSubstring(from: afterRange)
        )

        if handleListReturn(path: unit.path, before: before, after: after) {
            return true
        }
        if handleBlockquoteReturn(path: unit.path, before: before, after: after) {
            return true
        }
        guard let current = leafBlock(at: unit.path), let logical = logicalPath(for: unit.path) else {
            return false
        }
        let first: MarkdownBlock
        switch current {
            case .paragraph: first = .paragraph(before)
            case let .heading(level, _): first = .heading(level: level, content: before)
            default: return false
        }
        let replacement = rewritingDocument([unit.path: [first, .paragraph(after)]])
        applyStructuralReplacement(replacement, selection: MarkdownLogicalSelection(path: siblingPath(logical, offset: 1)))
        return true
    }

    func handleListReturn(
        path: EditorNodePath,
        before: [MarkdownInline],
        after: [MarkdownInline]
    ) -> Bool {
        guard path.components.count >= 3,
              case let .listItem(itemIndex) = path.components[path.components.count - 2],
              case let .itemBlock(itemBlockIndex) = path.components.last,
              itemBlockIndex == 0 else {
            return false
        }
        let listPath = EditorNodePath(Array(path.components.dropLast(2)))
        guard case var .list(list)? = blockAtPath(listPath), list.items.indices.contains(itemIndex),
              let logicalList = logicalPath(for: listPath) else {
            return false
        }
        if before.isEmpty, after.isEmpty, list.items[itemIndex].blocks.count == 1 {
            if case .listItemBlock = logicalList {
                let result = MarkdownEditingEngine.apply(.outdent, to: document, selection: MarkdownLogicalSelection(path: .listItemBlock(list: logicalList, item: itemIndex, block: 0)))
                if result.document != document {
                    applyStructuralReplacement(result.document, selection: result.selection); return true
                }
            }
            let precedingItems = Array(list.items[..<itemIndex])
            let followingItems = Array(list.items[(itemIndex + 1)...])
            var blocks: [MarkdownBlock] = []
            if !precedingItems.isEmpty {
                var precedingList = list
                precedingList.items = precedingItems
                blocks.append(.list(precedingList))
            }
            let paragraphOffset = blocks.count
            blocks.append(.paragraph([]))
            if !followingItems.isEmpty {
                var followingList = list
                followingList.items = followingItems
                if case let .ordered(start) = list.kind {
                    followingList.kind = .ordered(start: start + itemIndex + 1)
                }
                blocks.append(.list(followingList))
            }
            let replacement = rewritingDocument([listPath: blocks])
            applyStructuralReplacement(replacement, selection: MarkdownLogicalSelection(path: siblingPath(logicalList, offset: paragraphOffset)))
            return true
        }
        let remaining = Array(list.items[itemIndex].blocks.dropFirst())
        list.items[itemIndex].blocks = [.paragraph(before)]
        let taskState: MarkdownTaskState? = list.items[itemIndex].taskState == nil ? nil : .unchecked
        list.items.insert(MarkdownListItem(taskState: taskState, blocks: [.paragraph(after)] + remaining), at: itemIndex + 1)
        guard let replacement = replacingBlock(at: listPath, with: .list(list)) else {
            return false
        }
        applyStructuralReplacement(replacement, selection: MarkdownLogicalSelection(path: .listItemBlock(list: logicalList, item: itemIndex + 1, block: 0)))
        return true
    }

    func siblingPath(_ path: MarkdownLogicalPath, offset: Int) -> MarkdownLogicalPath {
        switch path {
            case let .block(index): .block(index + offset)
            case let .blockquote(parent, child): .blockquote(parent: parent, child: child + offset)
            case let .listItemBlock(list, item, block): .listItemBlock(list: list, item: item, block: block + offset)
            case .tableCell: path
        }
    }

    func handleBlockquoteReturn(path: EditorNodePath, before: [MarkdownInline], after: [MarkdownInline]) -> Bool {
        guard case let .blockquoteBlock(childIndex)? = path.components.last else {
            return false
        }
        let quotePath = EditorNodePath(Array(path.components.dropLast()))
        guard case var .blockquote(children)? = blockAtPath(quotePath), children.indices.contains(childIndex),
              let logicalQuote = logicalPath(for: quotePath) else {
            return false
        }
        let first: MarkdownBlock
        switch children[childIndex] {
            case .paragraph: first = .paragraph(before)
            case let .heading(level, _): first = .heading(level: level, content: before)
            default: return false
        }
        children.replaceSubrange(childIndex ... childIndex, with: [first, .paragraph(after)])
        guard let replacement = replacingBlock(at: quotePath, with: .blockquote(children)) else {
            return false
        }
        applyStructuralReplacement(replacement, selection: MarkdownLogicalSelection(path: .blockquote(parent: logicalQuote, child: childIndex + 1)))
        return true
    }

    func handleBackwardBoundaryDeletion(after unit: ProjectionUnit) -> Bool {
        let units = projection.index.units
        guard let unitIndex = units.firstIndex(where: { $0.path == unit.path }),
              units.indices.contains(unitIndex + 1) else {
            return false
        }
        let next = units[unitIndex + 1]
        if handleTopLevelJoin(first: unit.path, second: next.path) {
            return true
        }
        if handleListToTopLevelJoin(first: unit.path, second: next.path) {
            return true
        }
        return handleListItemJoin(first: unit.path, second: next.path)
    }

    func handleTopLevelJoin(first: EditorNodePath, second: EditorNodePath) -> Bool {
        guard first.components.count == 1,
              second.components.count == 1,
              case let .block(firstIndex) = first.components[0],
              case let .block(secondIndex) = second.components[0],
              secondIndex == firstIndex + 1,
              document.blocks.indices.contains(secondIndex),
              let firstContent = inlineContent(of: document.blocks[firstIndex]),
              let secondContent = inlineContent(of: document.blocks[secondIndex]) else {
            return false
        }
        let joined: MarkdownBlock = switch document.blocks[firstIndex] {
            case let .heading(level, _): .heading(level: level, content: firstContent + secondContent)
            default: .paragraph(firstContent + secondContent)
        }
        var replacement = document
        replacement.blocks.replaceSubrange(firstIndex ... secondIndex, with: [joined])
        applyStructuralReplacement(
            replacement,
            selection: MarkdownLogicalSelection(
                path: .block(firstIndex),
                utf16Offset: plainTextLength(firstContent)
            )
        )
        return true
    }

    func handleListToTopLevelJoin(first: EditorNodePath, second: EditorNodePath) -> Bool {
        guard first.components.count == 3,
              second.components.count == 1,
              case let .block(firstBlockIndex) = first.components[0],
              case let .block(secondBlockIndex) = second.components[0],
              secondBlockIndex == firstBlockIndex + 1,
              case let .listItem(itemIndex) = first.components[1],
              case let .itemBlock(itemBlockIndex) = first.components[2],
              document.blocks.indices.contains(secondBlockIndex),
              case var .list(list) = document.blocks[firstBlockIndex],
              itemIndex == list.items.indices.last,
              itemBlockIndex == list.items[itemIndex].blocks.indices.last,
              let firstContent = inlineContent(of: list.items[itemIndex].blocks[itemBlockIndex]),
              let secondContent = inlineContent(of: document.blocks[secondBlockIndex]) else {
            return false
        }
        let caretOffset = plainTextLength(firstContent)
        let joined: MarkdownBlock = switch list.items[itemIndex].blocks[itemBlockIndex] {
            case let .heading(level, _): .heading(level: level, content: firstContent + secondContent)
            default: .paragraph(firstContent + secondContent)
        }
        list.items[itemIndex].blocks[itemBlockIndex] = joined
        var replacement = document
        replacement.blocks[firstBlockIndex] = .list(list)
        replacement.blocks.remove(at: secondBlockIndex)
        applyStructuralReplacement(
            replacement,
            selection: MarkdownLogicalSelection(
                path: .listItemBlock(
                    list: .block(firstBlockIndex),
                    item: itemIndex,
                    block: itemBlockIndex
                ),
                utf16Offset: caretOffset
            )
        )
        return true
    }

    func handleListItemJoin(first: EditorNodePath, second: EditorNodePath) -> Bool {
        guard first.components.count >= 3, second.components.count == first.components.count,
              Array(first.components.dropLast(2)) == Array(second.components.dropLast(2)),
              case let .listItem(firstItem) = first.components[first.components.count - 2],
              case let .listItem(secondItem) = second.components[second.components.count - 2],
              secondItem == firstItem + 1,
              case .itemBlock(0) = first.components.last, case .itemBlock(0) = second.components.last else {
            return false
        }
        let listPath = EditorNodePath(Array(first.components.dropLast(2)))
        guard case var .list(list)? = blockAtPath(listPath), list.items.indices.contains(secondItem),
              case let .paragraph(firstContent) = list.items[firstItem].blocks.first,
              case let .paragraph(secondContent) = list.items[secondItem].blocks.first,
              let logicalList = logicalPath(for: listPath) else {
            return false
        }
        list.items[firstItem].blocks[0] = .paragraph(firstContent + secondContent)
        list.items[firstItem].blocks.append(contentsOf: list.items[secondItem].blocks.dropFirst())
        list.items.remove(at: secondItem)
        guard let replacement = replacingBlock(at: listPath, with: .list(list)) else {
            return false
        }
        applyStructuralReplacement(replacement, selection: MarkdownLogicalSelection(path: .listItemBlock(list: logicalList, item: firstItem, block: 0), utf16Offset: plainTextLength(firstContent)))
        return true
    }

    func inlineContent(of block: MarkdownBlock) -> [MarkdownInline]? {
        switch block {
            case let .paragraph(content),
                 let .heading(_, content): content
            default: nil
        }
    }

    func plainTextLength(_ inlines: [MarkdownInline]) -> Int {
        inlines.reduce(into: 0) { length, inline in
            switch inline {
                case let .text(value),
                     let .code(value),
                     let .html(value):
                    length += value.utf16.count
                case .softBreak,
                     .lineBreak,
                     .image:
                    length += 1
                case let .emphasis(children),
                     let .strong(children),
                     let .strikethrough(children),
                     let .link(_, _, children):
                    length += plainTextLength(children)
            }
        }
    }

    func applyStructuralReplacement(
        _ replacement: MarkdownDocument,
        selection: MarkdownLogicalSelection
    ) {
        guard let bridge else {
            return
        }
        let before = Snapshot(
            document: document,
            selectedRanges: bridge.markdownSelectedRanges,
            typingAttributes: bridge.markdownTypingAttributes,
            tableSelection: activeTableSelection
        )
        document = replacement
        pendingNativeEdits = []
        projection = makeProjection(document: replacement)
        installProjection(
            projection,
            selectedRanges: [projectionRange(for: selection) ?? NSRange(location: 0, length: 0)]
        )
        publishDocumentChange()
        let after = Snapshot(
            document: document,
            selectedRanges: bridge.markdownSelectedRanges,
            typingAttributes: bridge.markdownTypingAttributes,
            tableSelection: activeTableSelection
        )
        registerUndo(from: after, to: before)
    }

    func handleInsertionAfterTable(_ insertion: String, at path: EditorNodePath) -> Bool {
        guard path.components.count == 1,
              case let .block(blockIndex) = path.components[0],
              blockIndex == document.blocks.indices.last else {
            return false
        }
        let content: [MarkdownInline]
        let caretOffset: Int
        if insertion == "\n" {
            content = []
            caretOffset = 0
        } else {
            content = [.text(insertion)]
            caretOffset = insertion.utf16.count
        }
        var replacement = document
        replacement.blocks.append(.paragraph(content))
        applyStructuralReplacement(
            replacement,
            selection: MarkdownLogicalSelection(
                path: .block(blockIndex + 1),
                utf16Offset: caretOffset
            )
        )
        return true
    }

    func pasteBlockFragment(_ fragment: MarkdownDocument, replacing range: NSRange) -> Bool {
        let units = replacementUnits(in: range)
        guard let bridge, !fragment.blocks.isEmpty, let first = units.first, let last = units.last,
              let logical = logicalPath(for: first.path) else {
            return false
        }
        let firstStart = first.projectionRange.location
        let firstEnd = max(firstStart, first.projectionRange.upperBound - 1)
        let lastEnd = max(last.projectionRange.location, last.projectionRange.upperBound - 1)
        let beforeEnd = min(max(range.location, firstStart), firstEnd)
        let afterStart = min(max(NSMaxRange(range), last.projectionRange.location), lastEnd)
        let before = MarkdownAttributedInlineDecoder.decode(bridge.markdownTextStorage.attributedSubstring(from: NSRange(location: firstStart, length: beforeEnd - firstStart)))
        let after = MarkdownAttributedInlineDecoder.decode(bridge.markdownTextStorage.attributedSubstring(from: NSRange(location: afterStart, length: lastEnd - afterStart)))
        var blocks = fragment.blocks
        if !before.isEmpty {
            if let content = inlineContent(of: blocks[0]) {
                blocks[0] = replacingInlineContent(of: blocks[0], with: before + content)
            } else {
                blocks.insert(.paragraph(before), at: 0)
            }
        }
        let insertedCaretOffset: Int
        if let content = inlineContent(of: blocks[blocks.count - 1]) {
            insertedCaretOffset = plainTextLength(content)
            blocks[blocks.count - 1] = replacingInlineContent(of: blocks[blocks.count - 1], with: content + after)
        } else {
            insertedCaretOffset = 0
            blocks.append(.paragraph(after))
        }
        var replacements = Dictionary(uniqueKeysWithValues: units.map { ($0.path, [MarkdownBlock]()) })
        replacements[first.path] = blocks
        applyStructuralReplacement(rewritingDocument(replacements), selection: MarkdownLogicalSelection(path: siblingPath(logical, offset: blocks.count - 1), utf16Offset: insertedCaretOffset))
        return true
    }

    func replacingInlineContent(
        of block: MarkdownBlock,
        with content: [MarkdownInline]
    ) -> MarkdownBlock {
        switch block {
            case .paragraph:
                .paragraph(content)
            case let .heading(level, _):
                .heading(level: level, content: content)
            default:
                block
        }
    }

    func replacingNestedLeaf(
        in block: MarkdownBlock,
        components: [EditorNodePath.Component],
        with replacement: MarkdownBlock
    ) -> MarkdownBlock? {
        guard let first = components.first else {
            return replacement
        }
        switch first {
            case let .blockquoteBlock(child):
                guard case var .blockquote(children) = block, children.indices.contains(child),
                      let nested = replacingNestedLeaf(
                          in: children[child],
                          components: Array(components.dropFirst()),
                          with: replacement
                      ) else {
                    return nil
                }
                children[child] = nested
                return .blockquote(children)
            case let .listItem(item):
                guard components.count >= 2, case let .itemBlock(blockIndex) = components[1],
                      case var .list(list) = block, list.items.indices.contains(item),
                      list.items[item].blocks.indices.contains(blockIndex),
                      let nested = replacingNestedLeaf(
                          in: list.items[item].blocks[blockIndex],
                          components: Array(components.dropFirst(2)),
                          with: replacement
                      ) else {
                    return nil
                }
                list.items[item].blocks[blockIndex] = nested
                return .list(list)
            default:
                return nil
        }
    }

    func replacingImage(
        in block: MarkdownBlock,
        components: [EditorNodePath.Component],
        metadata: MarkdownImageMetadata
    ) -> MarkdownBlock? {
        guard let first = components.first else {
            return nil
        }
        switch first {
            case let .blockquoteBlock(child):
                guard case var .blockquote(children) = block,
                      children.indices.contains(child),
                      let updated = replacingImage(
                          in: children[child],
                          components: Array(components.dropFirst()),
                          metadata: metadata
                      ) else {
                    return nil
                }
                children[child] = updated
                return .blockquote(children)
            case let .listItem(item):
                guard components.count >= 2,
                      case let .itemBlock(blockIndex) = components[1],
                      case var .list(list) = block,
                      list.items.indices.contains(item),
                      list.items[item].blocks.indices.contains(blockIndex),
                      let updated = replacingImage(
                          in: list.items[item].blocks[blockIndex],
                          components: Array(components.dropFirst(2)),
                          metadata: metadata
                      ) else {
                    return nil
                }
                list.items[item].blocks[blockIndex] = updated
                return .list(list)
            case let .inline(index):
                switch block {
                    case let .paragraph(existingContent):
                        var content = existingContent
                        guard let updated = replacingImage(
                            in: content,
                            index: index,
                            components: Array(components.dropFirst()),
                            metadata: metadata
                        ) else {
                            return nil
                        }
                        content = updated
                        return .paragraph(content)
                    case let .heading(level, content):
                        guard let updated = replacingImage(
                            in: content,
                            index: index,
                            components: Array(components.dropFirst()),
                            metadata: metadata
                        ) else {
                            return nil
                        }
                        return .heading(level: level, content: updated)
                    default:
                        return nil
                }
            default:
                return nil
        }
    }

    func replacingImage(
        in inlines: [MarkdownInline],
        index: Int,
        components: [EditorNodePath.Component],
        metadata: MarkdownImageMetadata
    ) -> [MarkdownInline]? {
        guard inlines.indices.contains(index) else {
            return nil
        }
        var updated = inlines
        if components.isEmpty {
            guard case .image = updated[index] else {
                return nil
            }
            updated[index] = .image(
                source: metadata.source,
                title: metadata.title,
                children: [.text(metadata.altText)]
            )
            return updated
        }
        guard case let .inlineChild(childIndex) = components[0],
              let replacement = replacingImage(
                  in: updated[index],
                  childIndex: childIndex,
                  components: Array(components.dropFirst()),
                  metadata: metadata
              ) else {
            return nil
        }
        updated[index] = replacement
        return updated
    }

    func replacingImage(
        in inline: MarkdownInline,
        childIndex: Int,
        components: [EditorNodePath.Component],
        metadata: MarkdownImageMetadata
    ) -> MarkdownInline? {
        func replace(in children: [MarkdownInline]) -> [MarkdownInline]? {
            replacingImage(in: children, index: childIndex, components: components, metadata: metadata)
        }
        switch inline {
            case let .emphasis(children):
                return replace(in: children).map(MarkdownInline.emphasis)
            case let .strong(children):
                return replace(in: children).map(MarkdownInline.strong)
            case let .strikethrough(children):
                return replace(in: children).map(MarkdownInline.strikethrough)
            case let .link(destination, title, children):
                return replace(in: children).map {
                    .link(destination: destination, title: title, children: $0)
                }
            default:
                return nil
        }
    }

    func projectionKind(at path: EditorNodePath, in document: MarkdownDocument) -> ProjectionUnit.Kind? {
        guard let block = leafBlock(at: path, in: document) else {
            return nil
        }
        return switch block {
            case .paragraph: .paragraph
            case let .heading(level, _): .heading(level)
            case .codeBlock: .codeBlock
            case .html: .htmlBlock
            case .table: .table
            case .thematicBreak: .thematicBreak
            case .blockquote,
                 .list: nil
        }
    }

    func publishDocumentChange() {
        onCommandStateChange?()
        pendingLocalEchoes.append(document)
        if pendingLocalEchoes.count > 32 {
            pendingLocalEchoes.removeFirst(pendingLocalEchoes.count - 32)
        }
        onDocumentChange(document)
    }

    func installProjection(_ projection: DocumentProjection, selectedRanges: [NSRange]) {
        guard let bridge else {
            return
        }
        isUpdatingBridge = true
        bridge.replaceAttributedCharacters(
            in: NSRange(location: 0, length: bridge.markdownTextStorage.length),
            with: projection.attributedString
        )
        bridge.markdownSelectedRanges = restoredRanges(selectedRanges, in: projection)
        isUpdatingBridge = false
        if activeTableSelection == nil {
            selectionDidChange()
        }
    }

    func restoredRanges(_ ranges: [NSRange], in projection: DocumentProjection) -> [NSRange] {
        guard !ranges.isEmpty else {
            return [NSRange(location: 0, length: 0)]
        }
        return ranges.map { range in
            let location = min(max(0, range.location), projection.index.projectionUTF16Length)
            let length = min(max(0, range.length), projection.index.projectionUTF16Length - location)
            return NSRange(location: location, length: length)
        }
    }

    func leafBlock(at path: EditorNodePath) -> MarkdownBlock? {
        leafBlock(at: path, in: document)
    }

    func leafBlock(at path: EditorNodePath, in document: MarkdownDocument) -> MarkdownBlock? {
        guard case let .block(rootIndex)? = path.components.first,
              document.blocks.indices.contains(rootIndex) else {
            return nil
        }
        var block = document.blocks[rootIndex]
        var index = 1
        while index < path.components.count {
            switch path.components[index] {
                case let .blockquoteBlock(child):
                    guard case let .blockquote(children) = block, children.indices.contains(child) else {
                        return nil
                    }
                    block = children[child]
                    index += 1
                case let .listItem(item):
                    guard case let .list(list) = block, list.items.indices.contains(item),
                          index + 1 < path.components.count,
                          case let .itemBlock(blockIndex) = path.components[index + 1],
                          list.items[item].blocks.indices.contains(blockIndex) else {
                        return nil
                    }
                    block = list.items[item].blocks[blockIndex]
                    index += 2
                default:
                    return nil
            }
        }
        switch block {
            case .paragraph,
                 .heading,
                 .codeBlock,
                 .html,
                 .table,
                 .thematicBreak:
                return block
            case .blockquote,
                 .list:
                return nil
        }
    }

    func logicalSelection(for range: NSRange) -> MarkdownLogicalSelection? {
        guard let unit = projection.index.unit(atProjectionUTF16Offset: range.location),
              let path = logicalPath(for: unit.path) else {
            return nil
        }
        let contentEnd = max(unit.projectionRange.location, unit.projectionRange.upperBound - 1)
        let relativeLocation = max(0, min(range.location, contentEnd) - unit.projectionRange.location)
        let relativeEnd = max(relativeLocation, min(NSMaxRange(range), contentEnd) - unit.projectionRange.location)
        return MarkdownLogicalSelection(
            path: path,
            utf16Offset: relativeLocation,
            utf16Length: relativeEnd - relativeLocation
        )
    }

    func logicalPath(for path: EditorNodePath) -> MarkdownLogicalPath? {
        guard case let .block(index)? = path.components.first else {
            return nil
        }
        var result = MarkdownLogicalPath.block(index)
        var componentIndex = 1
        while componentIndex < path.components.count {
            switch path.components[componentIndex] {
                case let .blockquoteBlock(child):
                    result = .blockquote(parent: result, child: child)
                    componentIndex += 1
                case let .listItem(item):
                    guard componentIndex + 1 < path.components.count,
                          case let .itemBlock(block) = path.components[componentIndex + 1] else {
                        return nil
                    }
                    result = .listItemBlock(list: result, item: item, block: block)
                    componentIndex += 2
                default:
                    return nil
            }
        }
        return result
    }

    func projectionRange(for selection: MarkdownLogicalSelection) -> NSRange? {
        let projectedPath = switch selection.path {
            case let .tableCell(table, _, _): table
            default: selection.path
        }
        guard let unit = projection.index.units.first(where: { logicalPath(for: $0.path) == projectedPath }) else {
            return nil
        }
        if case .tableCell = selection.path {
            return NSRange(location: unit.projectionRange.location, length: 0)
        }
        let location = min(unit.projectionRange.location + selection.utf16Offset, unit.projectionRange.upperBound)
        let length = min(selection.utf16Length, unit.projectionRange.upperBound - location)
        return NSRange(location: location, length: length)
    }

    func registerUndo(from current: Snapshot, to previous: Snapshot, using undoManager: UndoManager? = nil) {
        guard let manager = undoManager ?? bridge?.undoManager else {
            return
        }
        manager.registerUndo(withTarget: self) { [weak manager] session in
            MainActor.assumeIsolated {
                session.restore(previous, inverse: current, undoManager: manager)
            }
        }
    }

    func restore(_ snapshot: Snapshot, inverse: Snapshot, undoManager: UndoManager?) {
        restoredSnapshotSinceUndoNotification = true
        document = snapshot.document
        activeTableSelection = validated(snapshot.tableSelection, in: snapshot.document)
        pendingNativeEdits = []
        needsCompositionFlush = false
        projection = makeProjection(document: document)
        installProjection(projection, selectedRanges: snapshot.selectedRanges)
        bridge?.markdownTypingAttributes = snapshot.typingAttributes
        publishDocumentChange()
        registerUndo(from: snapshot, to: inverse, using: undoManager)
    }
}
#endif
// Rebuilds attachment configuration after changing image resolution settings.

#if canImport(UIKit) || canImport(AppKit)
@MainActor extension MarkdownEditingSession {
    func canPerform(_ command: MarkdownEditorCommand) -> Bool {
        guard let bridge, let range = bridge.markdownSelectedRanges.first else {
            return false
        }
        if case .toggleInline = command {
            return activeTableSelection != nil || selectedUnits(in: range).contains { $0.kind != .table && $0.kind != .thematicBreak && $0.kind != .codeBlock && $0.kind != .htmlBlock }
        }
        if case .setLink = command {
            return canPerform(.toggleInline(.strong))
        }
        if case .removeLink = command, range.length == 0 {
            return isActive(command)
        }
        guard let selection = activeTableSelection.flatMap({ logicalSelection(for: $0) }) ?? logicalSelection(for: range) else {
            return false
        }
        switch command {
            case .convertBlock,
                 .convertList,
                 .insertImage,
                 .insertTable,
                 .insertThematicBreak:
                return activeTableSelection == nil
            default:
                return MarkdownEditingEngine.apply(command, to: document, selection: selection).document != document
        }
    }

    func isActive(_ command: MarkdownEditorCommand) -> Bool {
        guard let bridge, let range = bridge.markdownSelectedRanges.first else {
            return false
        }
        switch command {
            case let .toggleInline(style):
                return inlineStyleIsActive(style, range: range)
            case .setLink,
                 .removeLink:
                return (activeTableController?.activeTypingAttributes ?? bridge.markdownTypingAttributes)[.markdownEditorLinkDestination] != nil
            case let .convertBlock(style):
                return blockStyleIsActive(style, range: range)
            case let .convertList(style):
                guard let unit = projection.index.unit(atProjectionUTF16Offset: range.location),
                      let itemIndex = unit.path.components.lastIndex(where: {
                          if case .listItem = $0 {
                              return true
                          }; return false
                      }),
                      case let .list(list)? = blockAtPath(EditorNodePath(Array(unit.path.components[..<itemIndex]))) else {
                    return false
                }
                switch (style, list.kind) {
                    case (.task, _): return list.items.contains { $0.taskState != nil }
                    case (.unordered, .unordered): return list.items.allSatisfy { $0.taskState == nil }
                    case (.ordered, .ordered): return true
                    default: return false
                }
            case let .setTableColumnAlignment(alignment):
                guard let active = activeTableSelection, let controller = activeTableController,
                      controller.table.alignments.indices.contains(active.cell.position.column) else {
                    return false
                }
                return controller.table.alignments[active.cell.position.column] == alignment
            default: return false
        }
    }
}

private extension MarkdownEditingSession {
    func blockStyleIsActive(_ style: MarkdownBlockStyle, range: NSRange) -> Bool {
        guard let unit = projection.index.unit(atProjectionUTF16Offset: range.location),
              let block = leafBlock(at: unit.path) else {
            return false
        }
        switch (style, block) {
            case (.paragraph, .paragraph): return true
            case let (.heading(level), .heading(current, _)): return level == current
            case (.code, .codeBlock): return true
            case (.blockquote, _):
                return unit.path.components.contains { component in
                    if case .blockquoteBlock = component {
                        return true
                    }
                    return false
                }
            default: return false
        }
    }

    var activeTableController: MarkdownTableController? {
        guard let active = activeTableSelection,
              let unit = projection.index.unit(at: active.path), let storage = bridge?.markdownTextStorage,
              unit.projectionRange.location < storage.length else {
            return nil
        }
        return (storage.attribute(.attachment, at: unit.projectionRange.location, effectiveRange: nil) as? MarkdownTableAttachment)?.controller
    }

    func updateTableTypingAttributes(for command: MarkdownEditorCommand) -> Bool {
        guard let controller = activeTableController, let bridge else {
            return false
        }
        let saved = bridge.markdownTypingAttributes
        bridge.markdownTypingAttributes = controller.activeTypingAttributes
        let handled = updateTypingAttributes(for: command, bridge: bridge)
        if handled {
            controller.setTypingAttributes(bridge.markdownTypingAttributes)
        }
        bridge.markdownTypingAttributes = saved
        return handled
    }

    func inlineStyleIsActive(_ style: MarkdownInlineStyle, range: NSRange) -> Bool {
        let key: NSAttributedString.Key = switch style {
            case .strong: .markdownEditorStrong
            case .emphasis: .markdownEditorEmphasis
            case .strikethrough: .markdownEditorStrikethrough
            case .code: .markdownEditorCode
        }
        if let active = activeTableSelection, let controller = activeTableController {
            if active.cell.range.length == 0 {
                return (controller.activeTypingAttributes[key] as? NSNumber)?.boolValue == true
            }
            let row: MarkdownTableRow
            switch active.cell.position.section {
                case .header: row = controller.table.header
                case let .body(index):
                    guard controller.table.rows.indices.contains(index) else {
                        return false
                    }
                    row = controller.table.rows[index]
            }
            guard row.cells.indices.contains(active.cell.position.column) else {
                return false
            }
            let value = makeProjection(document: MarkdownDocument(blocks: [.paragraph(row.cells[active.cell.position.column].content)])).attributedString
            return hasAttribute(key, in: value, range: active.cell.range)
        }
        guard let bridge else {
            return false
        }
        if range.length == 0 {
            return (bridge.markdownTypingAttributes[key] as? NSNumber)?.boolValue == true
        }
        let units = selectedUnits(in: range)
        return !units.isEmpty && units.allSatisfy { unit in
            let content = NSRange(location: unit.projectionRange.location, length: max(0, unit.projectionRange.length - 1))
            let intersection = NSIntersectionRange(content, range)
            return intersection.length == 0 || hasAttribute(key, in: bridge.markdownTextStorage, range: intersection)
        }
    }

    func hasAttribute(_ key: NSAttributedString.Key, in text: NSAttributedString, range: NSRange) -> Bool {
        guard range.length > 0, NSMaxRange(range) <= text.length else {
            return false
        }
        var enabled = true
        text.enumerateAttribute(key, in: range) { value, run, _ in
            let characters = (text.string as NSString).substring(with: run)
            if !characters.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               (value as? NSNumber)?.boolValue != true {
                enabled = false
            }
        }
        return enabled
    }

    func selectedUnits(in range: NSRange) -> [ProjectionUnit] {
        if range.length == 0 {
            return projection.index.unit(atProjectionUTF16Offset: range.location).map { [$0] } ?? []
        }
        return projection.index.units.filter { NSIntersectionRange($0.projectionRange.nsRange, range).length > 0 }
    }

    func replacementUnits(in range: NSRange) -> [ProjectionUnit] {
        var units = selectedUnits(in: range)
        if range.length > 0, let last = units.last, NSMaxRange(range) == last.projectionRange.upperBound,
           let next = projection.index.unit(atProjectionUTF16Offset: NSMaxRange(range)), next.path != last.path {
            units.append(next)
        }
        return units
    }

    func editorPath(for path: MarkdownLogicalPath) -> EditorNodePath {
        switch path {
            case let .block(index): EditorNodePath([.block(index)])
            case let .blockquote(parent, child): editorPath(for: parent).appending(.blockquoteBlock(child))
            case let .listItemBlock(list, item, block): editorPath(for: list).appending(.listItem(item)).appending(.itemBlock(block))
            case let .tableCell(table, _, _): editorPath(for: table)
        }
    }

    func blockAtPath(_ path: EditorNodePath) -> MarkdownBlock? {
        guard case let .block(index)? = path.components.first, document.blocks.indices.contains(index) else {
            return nil
        }
        var block = document.blocks[index]
        var offset = 1
        while offset < path.components.count {
            switch path.components[offset] {
                case let .blockquoteBlock(child):
                    guard case let .blockquote(children) = block, children.indices.contains(child) else {
                        return nil
                    }
                    block = children[child]; offset += 1
                case let .listItem(item):
                    guard case let .list(list) = block, list.items.indices.contains(item), offset + 1 < path.components.count,
                          case let .itemBlock(child) = path.components[offset + 1], list.items[item].blocks.indices.contains(child) else {
                        return nil
                    }
                    block = list.items[item].blocks[child]; offset += 2
                default: return nil
            }
        }
        return block
    }

    func themesAreEqual(_ lhs: MarkdownEditorTheme, _ rhs: MarkdownEditorTheme) -> Bool {
        func same(_ a: [NSAttributedString.Key: Any], _ b: [NSAttributedString.Key: Any]) -> Bool {
            NSDictionary(dictionary: a).isEqual(to: b)
        }
        return same(lhs.bodyAttributes, rhs.bodyAttributes)
            && same(lhs.codeAttributes, rhs.codeAttributes)
            && same(lhs.sourceAttributes, rhs.sourceAttributes)
            && same(lhs.linkAttributes, rhs.linkAttributes)
            && same(lhs.objectPlaceholderAttributes, rhs.objectPlaceholderAttributes)
            && lhs.headingAttributes.count == rhs.headingAttributes.count
            && lhs.headingAttributes.allSatisfy { key, value in rhs.headingAttributes[key].map { same(value, $0) } ?? false }
    }

    func isParagraph(_ block: MarkdownBlock) -> Bool {
        if case .paragraph = block {
            return true
        }; return false
    }

    func attributedInsertion(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: bridge?.markdownTypingAttributes ?? theme.bodyAttributes)
    }

    /// Applies replacements to original structural paths, pruning only removed containers.
    func rewritingDocument(_ replacements: [EditorNodePath: [MarkdownBlock]]) -> MarkdownDocument {
        func visit(_ block: MarkdownBlock, at path: EditorNodePath) -> [MarkdownBlock] {
            if let replacement = replacements[path] {
                return replacement
            }
            switch block {
                case let .blockquote(children):
                    let updated = children.enumerated().flatMap { visit($0.element, at: path.appending(.blockquoteBlock($0.offset))) }
                    return updated.isEmpty ? [] : [.blockquote(updated)]
                case var .list(list):
                    list.items = list.items.enumerated().compactMap { index, item in
                        var item = item
                        item.blocks = item.blocks.enumerated().flatMap { visit($0.element, at: path.appending(.listItem(index)).appending(.itemBlock($0.offset))) }
                        return item.blocks.isEmpty ? nil : item
                    }
                    return list.items.isEmpty ? [] : [.list(list)]
                default: return [block]
            }
        }
        return Self.editableDocument(MarkdownDocument(blocks: document.blocks.enumerated().flatMap { visit($0.element, at: EditorNodePath([.block($0.offset)])) }))
    }

    func selectedDocument(in range: NSRange) -> MarkdownDocument {
        guard let bridge else {
            return MarkdownDocument()
        }
        func visit(_ block: MarkdownBlock, at path: EditorNodePath) -> MarkdownBlock? {
            switch block {
                case let .blockquote(children):
                    let selected = children.enumerated().compactMap { visit($0.element, at: path.appending(.blockquoteBlock($0.offset))) }
                    return selected.isEmpty ? nil : .blockquote(selected)
                case var .list(list):
                    var firstItem: Int?
                    list.items = list.items.enumerated().compactMap { index, item in
                        let selected = item.blocks.enumerated().compactMap { visit($0.element, at: path.appending(.listItem(index)).appending(.itemBlock($0.offset))) }
                        guard !selected.isEmpty else {
                            return nil
                        }
                        if firstItem == nil {
                            firstItem = index
                        }
                        return MarkdownListItem(taskState: item.taskState, blocks: selected)
                    }
                    if case let .ordered(start) = list.kind {
                        list.kind = .ordered(start: start + (firstItem ?? 0))
                    }
                    return list.items.isEmpty ? nil : .list(list)
                default:
                    guard let unit = projection.index.unit(at: path), NSIntersectionRange(unit.projectionRange.nsRange, range).length > 0 else {
                        return nil
                    }
                    let contentRange = NSRange(location: unit.projectionRange.location, length: max(0, unit.projectionRange.length - 1))
                    let selected = NSIntersectionRange(contentRange, range)
                    if selected.length == contentRange.length {
                        return block
                    }
                    return replacingRichContent(in: block, with: bridge.markdownTextStorage.attributedSubstring(from: selected))
            }
        }
        return MarkdownDocument(blocks: document.blocks.enumerated().compactMap { visit($0.element, at: EditorNodePath([.block($0.offset)])) })
    }

    /// Replaces a projected selection without guessing a single leaf from the resulting caret.
    @discardableResult func replaceProjectedRange(_ range: NSRange, with insertion: NSAttributedString) -> Bool {
        let units = replacementUnits(in: range)
        guard let bridge, let first = units.first,
              let last = units.last, let firstBlock = leafBlock(at: first.path) else {
            return false
        }
        let firstStart = first.projectionRange.location
        let firstEnd = max(firstStart, first.projectionRange.upperBound - 1)
        let lastStart = last.projectionRange.location
        let lastEnd = max(lastStart, last.projectionRange.upperBound - 1)
        let beforeEnd = min(max(range.location, firstStart), firstEnd)
        let afterStart = min(max(NSMaxRange(range), lastStart), lastEnd)
        let before = bridge.markdownTextStorage.attributedSubstring(from: NSRange(location: firstStart, length: beforeEnd - firstStart))
        let after = bridge.markdownTextStorage.attributedSubstring(from: NSRange(location: afterStart, length: lastEnd - afterStart))
        let joined = NSMutableAttributedString(attributedString: before)
        joined.append(insertion)
        joined.append(after)
        if insertion.string == "\n", first.kind != .codeBlock {
            let leading = MarkdownAttributedInlineDecoder.decode(before)
            let trailing = MarkdownAttributedInlineDecoder.decode(after)
            let firstReplacement = replacingInlineContent(of: firstBlock, with: leading)
            let leadingBlock = inlineContent(of: firstReplacement) == nil ? MarkdownBlock.paragraph(leading) : firstReplacement
            var replacements = Dictionary(uniqueKeysWithValues: units.map { ($0.path, [MarkdownBlock]()) })
            replacements[first.path] = [leadingBlock, .paragraph(trailing)]
            guard let logical = logicalPath(for: first.path) else {
                return false
            }
            applyStructuralReplacement(rewritingDocument(replacements), selection: MarkdownLogicalSelection(path: siblingPath(logical, offset: 1)))
            return true
        }
        let content = MarkdownAttributedInlineDecoder.decode(joined)
        let block: MarkdownBlock = switch firstBlock {
            case let .heading(level, _): .heading(level: level, content: content)
            case let .codeBlock(info, _) where first.path == last.path: .codeBlock(info: info, content: joined.string)
            default: .paragraph(content)
        }
        var replacements = Dictionary(uniqueKeysWithValues: units.map { ($0.path, [MarkdownBlock]()) })
        replacements[first.path] = [block]
        let replacement = rewritingDocument(replacements)
        guard let logical = logicalPath(for: first.path) else {
            return false
        }
        applyStructuralReplacement(replacement, selection: MarkdownLogicalSelection(path: logical, utf16Offset: before.length + insertion.length))
        return true
    }

    func performAcrossBlocks(_ command: MarkdownEditorCommand, selection: NSRange) -> Bool {
        let units = selectedUnits(in: selection)
        guard units.count > 1 else {
            return false
        }
        switch command {
            case .toggleInline,
                 .setLink,
                 .removeLink,
                 .convertBlock,
                 .convertList: break
            default: return false
        }
        guard let bridge else {
            return false
        }
        let before = Snapshot(document: document, selectedRanges: bridge.markdownSelectedRanges, typingAttributes: bridge.markdownTypingAttributes, tableSelection: activeTableSelection)
        var replacement = document
        if case let .convertList(style) = command, units.allSatisfy({ $0.path.components.count == 1 }),
           case let .block(firstIndex) = units[0].path.components[0], case let .block(lastIndex) = units[units.count - 1].path.components[0] {
            let items = replacement.blocks[firstIndex ... lastIndex].map { MarkdownListItem(taskState: style == .task ? .unchecked : nil, blocks: [$0]) }
            let kind: MarkdownListKind = if case let .ordered(start) = style {
                .ordered(start: start)
            } else {
                .unordered
            }
            replacement.blocks.replaceSubrange(firstIndex ... lastIndex, with: [.list(MarkdownList(kind: kind, isTight: true, items: items))])
        } else {
            let allStyled = if case let .toggleInline(style) = command {
                inlineStyleIsActive(style, range: selection)
            } else {
                false
            }
            for unit in units.reversed() {
                let start = max(selection.location, unit.projectionRange.location)
                let end = min(NSMaxRange(selection), unit.projectionRange.upperBound - 1)
                guard end >= start, let path = logicalPath(for: unit.path) else {
                    continue
                }
                if case let .toggleInline(style) = command, !allStyled, inlineStyleIsActive(style, range: NSRange(location: start, length: end - start)) {
                    continue
                }
                let logical = MarkdownLogicalSelection(path: path, utf16Offset: start - unit.projectionRange.location, utf16Length: end - start)
                replacement = MarkdownEditingEngine.apply(command, to: replacement, selection: logical).document
            }
        }
        guard replacement != document else {
            return true
        }
        document = replacement
        pendingNativeEdits = []
        projection = makeProjection(document: document)
        installProjection(projection, selectedRanges: before.selectedRanges)
        publishDocumentChange()
        registerUndo(from: Snapshot(document: document, selectedRanges: bridge.markdownSelectedRanges, typingAttributes: bridge.markdownTypingAttributes), to: before)
        return true
    }
}
#endif
