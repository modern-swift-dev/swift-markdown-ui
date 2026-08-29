import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let tableContextCommands: [(String, MarkdownEditorCommand)] = [
    ("Add row", .insertTableRow),
    ("Delete row", .deleteTableRow),
    ("Move row up", .moveTableRow(.backward)),
    ("Move row down", .moveTableRow(.forward)),
    ("Add column", .insertTableColumn),
    ("Delete column", .deleteTableColumn),
    ("Move column left", .moveTableColumn(.backward)),
    ("Move column right", .moveTableColumn(.forward)),
    ("Align left", .setTableColumnAlignment(.left)),
    ("Align center", .setTableColumnAlignment(.center)),
    ("Align right", .setTableColumnAlignment(.right))
]

/// The address of a cell in a rendered table attachment.
public struct MarkdownTableCellPosition: Hashable, Sendable {
    /// Chooses the header or a zero-based body row.
    public enum Section: Hashable, Sendable {
        /// The table header.
        case header
        /// A zero-based body row.
        case body(row: Int)
    }

    /// Header or body row containing the cell.
    public var section: Section
    /// Zero-based column index.
    public var column: Int

    /// Creates a cell address.
    public init(section: Section, column: Int) {
        self.section = section
        self.column = column
    }
}

/// The visual role of a row in a table attachment.
public enum MarkdownTableRowKind: Hashable, Sendable {
    /// The header row.
    case header
    /// A body row.
    case body
}

/// The native caret or selection owned by one editable table cell.
struct MarkdownTableCellSelection: Equatable, Sendable {
    var position: MarkdownTableCellPosition
    var range: NSRange
}

private func clamped(_ range: NSRange, toUTF16Length length: Int) -> NSRange {
    let location = min(max(0, range.location), length)
    return NSRange(location: location, length: min(max(0, range.length), length - location))
}

/// Mutable table state shared by an attachment and its native view provider.
@MainActor public final class MarkdownTableController {
    /// Current table model. Mutations preserve rectangular cell arrays.
    public private(set) var table: MarkdownTable
    /// Callback invoked after a table mutation.
    public var onChange: ((MarkdownTable) -> Void)?
    /// Current nested text selection, when a table cell owns first responder.
    private(set) var activeSelection: MarkdownTableCellSelection?
    /// Reports nested focus changes to the enclosing editor session.
    var onSelectionChange: ((MarkdownTableCellSelection?) -> Void)?

    // The grid owns presentation updates; the document owner retains onChange.
    var onPresentationChange: (() -> Void)?
    var activeTypingAttributes: [NSAttributedString.Key: Any] = [:]
    var onTypingAttributesChange: (([NSAttributedString.Key: Any]) -> Void)?

    func setTypingAttributes(_ attributes: [NSAttributedString.Key: Any]) {
        onTypingAttributesChange?(attributes)
        activeTypingAttributes = attributes
    }

    /// Creates a controller with an optional change callback.
    public init(table: MarkdownTable, onChange: ((MarkdownTable) -> Void)? = nil) {
        self.table = table
        self.onChange = onChange
    }

    func configureSelection(
        _ selection: MarkdownTableCellSelection?,
        onChange: @escaping (MarkdownTableCellSelection?) -> Void
    ) {
        activeSelection = selection
        onSelectionChange = onChange
    }

    func updateSelection(at position: MarkdownTableCellPosition, range: NSRange) {
        let selection = MarkdownTableCellSelection(position: position, range: range)
        guard selection != activeSelection else {
            return
        }
        activeSelection = selection
        onSelectionChange?(selection)
    }

    func endSelection(at position: MarkdownTableCellPosition) {
        guard activeSelection?.position == position else {
            return
        }
        activeSelection = nil
        onSelectionChange?(nil)
    }

    /// Number of columns after considering every row and alignment marker.
    public var columnCount: Int {
        max(1, table.alignments.count, table.header.cells.count, table.rows.map(\.cells.count).max() ?? 0)
    }

    /// Returns normalized Markdown source for one cell.
    public func source(at position: MarkdownTableCellPosition) -> String? {
        guard let cell = cell(at: position) else {
            return nil
        }
        return MarkdownTableCellSourceCodec.source(for: cell.content)
    }

    /// Parses and stores one cell's Markdown source, then notifies the owner.
    public func updateCell(at position: MarkdownTableCellPosition, source: String) {
        guard position.column >= 0 else {
            return
        }
        if case let .body(row) = position.section, !table.rows.indices.contains(row) {
            return
        }
        ensureColumnCount(atLeast: position.column + 1)
        updateCell(at: position, content: MarkdownTableCellSourceCodec.inlines(from: source))
    }

    func updateCell(at position: MarkdownTableCellPosition, content: [MarkdownInline]) {
        guard cell(at: position) != nil else {
            return
        }
        switch position.section {
            case .header:
                table.header.cells[position.column].content = content
            case let .body(row):
                table.rows[row].cells[position.column].content = content
        }
        notifyChange()
    }

    /// Returns the next editable cell in reading order, appending a row at the end.
    @discardableResult public func moveForward(from position: MarkdownTableCellPosition) -> MarkdownTableCellPosition? {
        let positions = allPositions
        guard let index = positions.firstIndex(of: position) else {
            return positions.first
        }
        if index + 1 < positions.count {
            return positions[index + 1]
        }
        appendRow()
        return MarkdownTableCellPosition(section: .body(row: table.rows.count - 1), column: 0)
    }

    /// Returns the preceding editable cell in reading order.
    public func moveBackward(from position: MarkdownTableCellPosition) -> MarkdownTableCellPosition? {
        let positions = allPositions
        guard let index = positions.firstIndex(of: position), index > 0 else {
            return nil
        }
        return positions[index - 1]
    }

    /// Returns the cell below the supplied position, appending a row if needed.
    @discardableResult public func moveDown(from position: MarkdownTableCellPosition) -> MarkdownTableCellPosition? {
        guard position.column >= 0, position.column < columnCount else {
            return nil
        }
        switch position.section {
            case .header:
                if table.rows.isEmpty {
                    appendRow()
                }
                return MarkdownTableCellPosition(section: .body(row: 0), column: position.column)
            case let .body(row):
                if row + 1 == table.rows.count {
                    appendRow()
                }
                guard row + 1 < table.rows.count else {
                    return nil
                }
                return MarkdownTableCellPosition(section: .body(row: row + 1), column: position.column)
        }
    }

    /// Appends an empty body row.
    public func appendRow() {
        let count = max(columnCount, 1)
        ensureColumnCount(atLeast: count)
        table.rows.append(MarkdownTableRow(cells: emptyCells(count: count)))
        notifyChange()
    }

    /// Inserts an empty body row at a zero-based index.
    public func insertRow(at index: Int) {
        guard index >= 0, index <= table.rows.count else {
            return
        }
        let count = max(columnCount, 1)
        ensureColumnCount(atLeast: count)
        table.rows.insert(MarkdownTableRow(cells: emptyCells(count: count)), at: index)
        notifyChange()
    }

    /// Deletes the body row at a zero-based index.
    public func deleteRow(at index: Int) {
        guard table.rows.indices.contains(index) else {
            return
        }
        table.rows.remove(at: index)
        notifyChange()
    }

    /// Moves a body row to another zero-based index.
    public func moveRow(from sourceIndex: Int, to destinationIndex: Int) {
        guard table.rows.indices.contains(sourceIndex), destinationIndex >= 0,
              destinationIndex < table.rows.count, sourceIndex != destinationIndex else {
            return
        }
        let row = table.rows.remove(at: sourceIndex)
        table.rows.insert(row, at: destinationIndex)
        notifyChange()
    }

    /// Inserts an empty column with the requested alignment.
    public func insertColumn(at index: Int, alignment: MarkdownTableAlignment = .none) {
        guard index >= 0, index <= columnCount else {
            return
        }
        ensureColumnCount(atLeast: columnCount)
        table.header.cells.insert(MarkdownTableCell(content: []), at: index)
        for rowIndex in table.rows.indices {
            table.rows[rowIndex].cells.insert(MarkdownTableCell(content: []), at: index)
        }
        table.alignments.insert(alignment, at: index)
        notifyChange()
    }

    /// Deletes a column from the header, body rows, and alignment list.
    public func deleteColumn(at index: Int) {
        guard index >= 0, index < columnCount else {
            return
        }
        if table.header.cells.indices.contains(index) {
            table.header.cells.remove(at: index)
        }
        for rowIndex in table.rows.indices where table.rows[rowIndex].cells.indices.contains(index) {
            table.rows[rowIndex].cells.remove(at: index)
        }
        if table.alignments.indices.contains(index) {
            table.alignments.remove(at: index)
        }
        notifyChange()
    }

    /// Moves a column in the header, body rows, and alignment list.
    public func moveColumn(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0, destinationIndex >= 0, sourceIndex < columnCount,
              destinationIndex < columnCount, sourceIndex != destinationIndex else {
            return
        }
        ensureColumnCount(atLeast: columnCount)
        moveElement(in: &table.header.cells, from: sourceIndex, to: destinationIndex)
        for rowIndex in table.rows.indices {
            moveElement(in: &table.rows[rowIndex].cells, from: sourceIndex, to: destinationIndex)
        }
        moveElement(in: &table.alignments, from: sourceIndex, to: destinationIndex)
        notifyChange()
    }

    /// Updates one column's alignment marker.
    public func setAlignment(_ alignment: MarkdownTableAlignment, forColumn index: Int) {
        guard index >= 0, index < columnCount else {
            return
        }
        ensureColumnCount(atLeast: columnCount)
        table.alignments[index] = alignment
        notifyChange()
    }

    /// Returns whether a cell belongs to the header or a body row.
    public func rowKind(at position: MarkdownTableCellPosition) -> MarkdownTableRowKind {
        switch position.section {
            case .header: .header
            case .body: .body
        }
    }

    private var allPositions: [MarkdownTableCellPosition] {
        guard columnCount > 0 else {
            return []
        }
        var result = (0 ..< columnCount).map {
            MarkdownTableCellPosition(section: .header, column: $0)
        }
        for row in table.rows.indices {
            result.append(contentsOf: (0 ..< columnCount).map {
                MarkdownTableCellPosition(section: .body(row: row), column: $0)
            })
        }
        return result
    }

    private func cell(at position: MarkdownTableCellPosition) -> MarkdownTableCell? {
        guard position.column >= 0 else {
            return nil
        }
        switch position.section {
            case .header:
                guard table.header.cells.indices.contains(position.column) else {
                    return nil
                }
                return table.header.cells[position.column]
            case let .body(row):
                guard table.rows.indices.contains(row), table.rows[row].cells.indices.contains(position.column) else {
                    return nil
                }
                return table.rows[row].cells[position.column]
        }
    }

    private func ensureColumnCount(atLeast requestedCount: Int) {
        let count = max(requestedCount, columnCount)
        while table.header.cells.count < count {
            table.header.cells.append(MarkdownTableCell(content: []))
        }
        for rowIndex in table.rows.indices {
            while table.rows[rowIndex].cells.count < count {
                table.rows[rowIndex].cells.append(MarkdownTableCell(content: []))
            }
        }
        while table.alignments.count < count {
            table.alignments.append(.none)
        }
    }

    private func emptyCells(count: Int) -> [MarkdownTableCell] {
        (0 ..< count).map { _ in MarkdownTableCell(content: []) }
    }

    private func moveElement(in values: inout [some Any], from sourceIndex: Int, to destinationIndex: Int) {
        let value = values.remove(at: sourceIndex)
        values.insert(value, at: destinationIndex)
    }

    private func notifyChange() {
        onPresentationChange?()
        onChange?(table)
    }
}

private enum MarkdownTableCellSourceCodec {
    static let lineBreakHTML = "<br />"

    static func source(for inlines: [MarkdownInline]) -> String {
        guard !inlines.isEmpty else {
            return ""
        }
        var lines: [[MarkdownInline]] = [[]]
        for inline in inlines {
            if isEditableLineBreak(inline) {
                lines.append([])
            } else {
                lines[lines.count - 1].append(editableInline(inline))
            }
        }
        return lines.map(serializedLine).joined(separator: "\n")
    }

    private static func serializedLine(_ inlines: [MarkdownInline]) -> String {
        guard !inlines.isEmpty else {
            return ""
        }
        var source = MarkdownDocument(blocks: [.paragraph(inlines)]).markdown
        if source.hasSuffix("\n") {
            source.removeLast()
        }
        return source
    }

    static func inlines(from source: String) -> [MarkdownInline] {
        guard !source.isEmpty else {
            return []
        }
        var inlines: [MarkdownInline] = []
        for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 {
                inlines.append(.html(lineBreakHTML))
            }
            inlines.append(contentsOf: parsedInlines(from: String(line)))
        }
        return inlines
    }

    private static func parsedInlines(from source: String) -> [MarkdownInline] {
        guard !source.isEmpty else {
            return []
        }
        let document = MarkdownDocument(markdown: source)
        guard document.blocks.count == 1 else {
            return [.text(source)]
        }
        switch document.blocks[0] {
            case let .paragraph(content),
                 let .heading(_, content):
                return content
            default:
                return [.text(source)]
        }
    }

    static func editableInline(_ inline: MarkdownInline) -> MarkdownInline {
        switch inline {
            case let .html(value) where isLineBreakHTML(value):
                .softBreak
            case .softBreak,
                 .lineBreak:
                .softBreak
            case let .emphasis(children):
                .emphasis(children.map(editableInline))
            case let .strong(children):
                .strong(children.map(editableInline))
            case let .strikethrough(children):
                .strikethrough(children.map(editableInline))
            case let .link(destination, title, children):
                .link(destination: destination, title: title, children: children.map(editableInline))
            case let .image(source, title, children):
                .image(source: source, title: title, children: children.map(editableInline))
            default:
                inline
        }
    }

    private static func isLineBreakHTML(_ value: String) -> Bool {
        let compact = value.lowercased().filter { !$0.isWhitespace }
        return compact == "<br>" || compact == "<br/>"
    }

    private static func isEditableLineBreak(_ inline: MarkdownInline) -> Bool {
        switch inline {
            case .softBreak,
                 .lineBreak:
                true
            case let .html(value):
                isLineBreakHTML(value)
            default:
                false
        }
    }
}

#if canImport(UIKit) || canImport(AppKit)
@MainActor private extension MarkdownTableController {
    func richText(at position: MarkdownTableCellPosition) -> NSAttributedString {
        let content = (cell(at: position)?.content ?? []).map(MarkdownTableCellSourceCodec.editableInline)
        let projection = MarkdownProjectionBuilder().build(document: MarkdownDocument(blocks: [.paragraph(content)]))
        let result = NSMutableAttributedString(attributedString: projection.attributedString)
        if result.string.hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        if position.section == .header {
            result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { value, range, _ in
                #if canImport(UIKit)
                let font = value as? UIFont ?? .preferredFont(forTextStyle: .body)
                if let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitBold)) {
                    result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: range)
                }
                #elseif canImport(AppKit)
                let font = value as? NSFont ?? .preferredFont(forTextStyle: .body)
                result.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: range)
                #endif
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment(at: position)
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    func alignment(at position: MarkdownTableCellPosition) -> NSTextAlignment {
        switch table.alignments.indices.contains(position.column) ? table.alignments[position.column] : .none {
            case .none,
                 .left: .left
            case .center: .center
            case .right: .right
        }
    }

    func updateRichCell(at position: MarkdownTableCellPosition, text: NSAttributedString) {
        let content = MarkdownAttributedInlineDecoder.decode(text).map { inline -> MarkdownInline in
            switch inline {
                case .softBreak,
                     .lineBreak: .html("<br />")
                default: inline
            }
        }
        updateCell(at: position, content: content)
    }
}

enum MarkdownTableColumnLayout {
    static let minimumColumnWidth: CGFloat = 44

    static func widths(preferredWidths: [CGFloat], availableWidth: CGFloat?) -> [CGFloat] {
        guard !preferredWidths.isEmpty else {
            return []
        }
        let preferred = preferredWidths.map { max($0, minimumColumnWidth) }
        guard let availableWidth, availableWidth.isFinite, availableWidth > 0 else {
            return preferred
        }

        let minimum = min(minimumColumnWidth, availableWidth / CGFloat(preferred.count))
        let minimumTotal = minimum * CGFloat(preferred.count)
        guard preferred.reduce(0, +) > availableWidth else {
            return preferred
        }
        guard availableWidth > minimumTotal else {
            return Array(repeating: availableWidth / CGFloat(preferred.count), count: preferred.count)
        }

        var widths = preferred
        var overflow = widths.reduce(0, +) - availableWidth
        while overflow > 0.001 {
            guard let widest = widths.max() else {
                break
            }
            let widestIndices = widths.indices.filter { abs(widths[$0] - widest) < 0.001 }
            let nextWidth = widths.indices
                .filter { !widestIndices.contains($0) }
                .map { widths[$0] }
                .max() ?? minimum
            let lowerBound = max(nextWidth, minimum)
            let reducible = (widest - lowerBound) * CGFloat(widestIndices.count)
            if reducible >= overflow {
                let reduction = overflow / CGFloat(widestIndices.count)
                for index in widestIndices {
                    widths[index] -= reduction
                }
                overflow = 0
            } else {
                for index in widestIndices {
                    widths[index] = lowerBound
                }
                overflow -= reducible
            }
        }
        return widths
    }
}

private func markdownTableAvailableWidth(
    parentWidth: CGFloat,
    textContainer: NSTextContainer?
) -> CGFloat? {
    if let textContainer {
        let width = textContainer.size.width - 2 * textContainer.lineFragmentPadding
        if width.isFinite, width > 0 {
            return width
        }
    }
    if parentWidth.isFinite, parentWidth > 0 {
        return parentWidth
    }
    return nil
}
#endif

#if canImport(UIKit) || canImport(AppKit)
/// An attachment that renders an editable native grid for a Markdown table.
public final class MarkdownTableAttachment: NSTextAttachment, @unchecked Sendable {
    /// Controller shared with the platform-specific attachment view.
    public let controller: MarkdownTableController

    @MainActor public var table: MarkdownTable {
        controller.table
    }

    @MainActor public var onChange: ((MarkdownTable) -> Void)? {
        get { controller.onChange }
        set { controller.onChange = newValue }
    }

    @MainActor public init(table: MarkdownTable, onChange: ((MarkdownTable) -> Void)? = nil) {
        self.controller = MarkdownTableController(table: table, onChange: onChange)
        super.init(data: nil, ofType: "com.modernswiftdev.markdown-ui-editor.table")
        allowsTextAttachmentView = true
        lineLayoutPadding = 4
    }

    /// Restores an attachment without a table controller from an archive.
    public required init?(coder: NSCoder) {
        self.controller = MainActor.assumeIsolated {
            MarkdownTableController(
                table: MarkdownTable(alignments: [], header: MarkdownTableRow(cells: []), rows: [])
            )
        }
        super.init(coder: coder)
        allowsTextAttachmentView = true
    }

    #if canImport(UIKit)
    /// Returns the UIKit grid provider for this attachment.
    override public func viewProvider(
        for parentView: UIView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        let provider = MarkdownTableAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
        provider.availableWidth = markdownTableAvailableWidth(
            parentWidth: 0,
            textContainer: textContainer
        )
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }

    #elseif canImport(AppKit)
    /// Returns the AppKit grid provider for this attachment.
    override public func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        let provider = MarkdownTableAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
        provider.availableWidth = markdownTableAvailableWidth(
            parentWidth: 0,
            textContainer: textContainer
        )
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
    #endif
}
#endif

#if canImport(UIKit)
/// Creates the UIKit view used to edit a `MarkdownTableAttachment`.
public final class MarkdownTableAttachmentViewProvider: NSTextAttachmentViewProvider {
    var availableWidth: CGFloat?

    override public func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        let width = markdownTableAvailableWidth(parentWidth: proposedLineFragment.width, textContainer: textContainer)
        guard let grid = view as? UIKitMarkdownTableGridView else {
            return .zero
        }
        let resolvedWidth = width ?? availableWidth
        return MainActor.assumeIsolated {
            grid.updateAvailableWidth(resolvedWidth)
            return CGRect(origin: .zero, size: grid.intrinsicContentSize)
        }
    }

    /// Creates the native UIKit table grid.
    override public func loadView() {
        guard let attachment = textAttachment as? MarkdownTableAttachment else {
            view = nil
            return
        }
        let controller = attachment.controller
        let maximumWidth = availableWidth
        let grid = MainActor.assumeIsolated {
            UIKitMarkdownTableGridView(controller: controller, maximumWidth: maximumWidth)
        }
        MainActor.assumeIsolated {
            let size = grid.intrinsicContentSize
            grid.bounds.size = size
            grid.layoutIfNeeded()
        }
        tracksTextAttachmentViewBounds = true
        view = grid
    }
}

@MainActor private final class UIKitMarkdownTableGridView: UIView, UITextViewDelegate {
    private let controller: MarkdownTableController
    private var maximumWidth: CGFloat?
    private let stack = UIStackView()
    private var fields: [MarkdownTableCellPosition: MarkdownTableCellTextView] = [:]
    private var columnWidthConstraints: [[NSLayoutConstraint]] = []
    private var isEditingCell = false
    private var rowStacks: [UIStackView] = []
    private var rowHeightConstraints: [NSLayoutConstraint] = []

    init(controller: MarkdownTableController, maximumWidth: CGFloat?) {
        self.controller = controller
        self.maximumWidth = maximumWidth
        super.init(frame: .zero)
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        rebuild()
        controller.onPresentationChange = { [weak self] in
            guard let self, !self.isEditingCell else {
                return
            }
            self.rebuild()
            self.resizeAttachment()
        }
        controller.onTypingAttributesChange = { [weak self] attributes in
            guard let self, let selection = self.controller.activeSelection else {
                return
            }
            guard let field = self.fields[selection.position] else {
                return
            }
            field.selectedRange = clamped(selection.range, toUTF16Length: field.textStorage.length)
            field.becomeFirstResponder()
            field.typingAttributes = attributes
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: CGSize {
        stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let field = textView as? MarkdownTableCellTextView else {
            return
        }
        controller.activeTypingAttributes = field.typingAttributes
        controller.updateSelection(at: field.position, range: field.selectedRange)
        if field.markedTextRange == nil {
            isEditingCell = true
            controller.updateRichCell(at: field.position, text: field.textStorage)
            isEditingCell = false
        }
        updateColumnWidths()
        resizeAttachment()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        guard let field = textView as? MarkdownTableCellTextView else {
            return
        }
        controller.activeTypingAttributes = field.typingAttributes
        controller.updateSelection(at: field.position, range: field.selectedRange)
    }

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let field = textView as? MarkdownTableCellTextView,
              let editor = field.markdownEditor else {
            return nil
        }
        controller.updateSelection(at: field.position, range: range)
        let groups = [
            ("Style", range.length > 0 ? MarkdownEditorCommand.contextualInlineCommands : []),
            ("Table", tableContextCommands)
        ]
        let menus = groups.filter { !$0.1.isEmpty }.map { title, commands in
            UIMenu(title: title, children: commands.map { title, command in
                UIAction(title: title, attributes: editor.canPerform(command) ? [] : [.disabled]) { [weak self, weak field] _ in
                    guard let self, let field, let editor = field.markdownEditor else {
                        return
                    }
                    field.becomeFirstResponder()
                    field.selectedRange = range
                    self.controller.updateSelection(at: field.position, range: range)
                    editor.perform(command)
                }
            })
        }
        return UIMenu(children: suggestedActions + menus)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard let field = textView as? MarkdownTableCellTextView, field.isFirstResponder else {
            return
        }
        controller.activeTypingAttributes = field.typingAttributes
        controller.updateSelection(at: field.position, range: field.selectedRange)
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        fields.removeAll()
        columnWidthConstraints.removeAll()
        rowStacks.removeAll()
        rowHeightConstraints.removeAll()
        let count = max(controller.columnCount, 1)
        addRow(kind: .header, row: nil, columnCount: count)
        for row in controller.table.rows.indices {
            addRow(kind: .body, row: row, columnCount: count)
        }
        updateColumnWidths()
    }

    private func addRow(kind: MarkdownTableRowKind, row: Int?, columnCount: Int) {
        let rowStack = UIStackView()
        rowStack.axis = .horizontal
        rowStack.spacing = 0
        rowStack.distribution = .fill
        for column in 0 ..< columnCount {
            let section: MarkdownTableCellPosition.Section = row.map { .body(row: $0) } ?? .header
            let position = MarkdownTableCellPosition(section: section, column: column)
            let field = MarkdownTableCellTextView(position: position)
            field.attributedText = controller.richText(at: position)
            field.textAlignment = controller.alignment(at: position)
            field.delegate = self
            field.layer.borderColor = UIColor.opaqueSeparator.cgColor
            field.layer.borderWidth = 1 / UIScreen.main.scale
            field.typingAttributes = [.font: UIFont.preferredFont(forTextStyle: .body)]
            field.backgroundColor = kind == .header ? .secondarySystemBackground : .systemBackground
            field.isScrollEnabled = false
            field.textContainerInset = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
            field.textContainer.lineFragmentPadding = 0
            field.setContentHuggingPriority(.required, for: .vertical)
            field.accessibilityLabel = kind == .header ? "Table header, column \(column + 1)" : "Table row \((row ?? 0) + 1), column \(column + 1)"
            field.onTab = { [weak self, weak field] backwards in
                guard let self, let field else {
                    return
                }
                let destination = backwards
                    ? self.controller.moveBackward(from: field.position)
                    : self.controller.moveForward(from: field.position)
                if let destination {
                    self.rebuildIfNeededAndFocus(destination)
                }
            }
            fields[position] = field
            let widthConstraint = field.widthAnchor.constraint(equalToConstant: MarkdownTableColumnLayout.minimumColumnWidth)
            widthConstraint.isActive = true
            if columnWidthConstraints.indices.contains(column) {
                columnWidthConstraints[column].append(widthConstraint)
            } else {
                columnWidthConstraints.append([widthConstraint])
            }
            rowStack.addArrangedSubview(field)
        }
        stack.addArrangedSubview(rowStack)
        rowStacks.append(rowStack)
        let heightConstraint = rowStack.heightAnchor.constraint(equalToConstant: 28)
        heightConstraint.isActive = true
        rowHeightConstraints.append(heightConstraint)
    }

    private func updateColumnWidths() {
        let columnCount = max(controller.columnCount, 1)
        let preferredWidths = (0 ..< columnCount).map { column in
            fields
                .filter { $0.key.column == column }
                .map { _, field in
                    let textWidth = field.attributedText.size().width
                    return ceil(textWidth) + field.textContainerInset.left + field.textContainerInset.right + 2
                }
                .max() ?? MarkdownTableColumnLayout.minimumColumnWidth
        }
        let widths = MarkdownTableColumnLayout.widths(
            preferredWidths: preferredWidths,
            availableWidth: maximumWidth
        )
        for column in widths.indices {
            for constraint in columnWidthConstraints[column] {
                constraint.constant = widths[column]
            }
            for field in fields where field.key.column == column {
                field.value.layoutWidth = widths[column]
                field.value.invalidateIntrinsicContentSize()
            }
        }
        for row in rowStacks.indices {
            let height = rowStacks[row].arrangedSubviews
                .compactMap { $0 as? MarkdownTableCellTextView }
                .map(\.measuredHeight)
                .max() ?? 28
            rowHeightConstraints[row].constant = height
        }
        setNeedsLayout()
    }

    func updateAvailableWidth(_ width: CGFloat?) {
        guard maximumWidth != width else {
            return
        }
        maximumWidth = width
        updateColumnWidths()
        resizeAttachment()
    }

    private func resizeAttachment() {
        invalidateIntrinsicContentSize()
        let size = intrinsicContentSize
        if frame.size != size {
            frame.size = size
            // UIKit does not consistently invalidate the containing text fragment
            // when an attachment view grows during a nested text edit.
            var ancestor = superview
            while let view = ancestor {
                if let editor = view as? MarkdownTextView {
                    if let manager = editor.textLayoutManager {
                        manager.invalidateLayout(for: manager.documentRange)
                    }
                    editor.setNeedsLayout()
                    break
                }
                ancestor = view.superview
            }
        }
    }

    private func rebuildIfNeededAndFocus(_ position: MarkdownTableCellPosition) {
        if fields[position] == nil {
            rebuild()
        }
        guard let field = fields[position] else {
            return
        }
        field.selectedRange = NSRange(location: 0, length: 0)
        controller.updateSelection(at: position, range: field.selectedRange)
        field.becomeFirstResponder()
        invalidateIntrinsicContentSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let selection = controller.activeSelection,
              let field = fields[selection.position] else {
            return
        }
        field.selectedRange = clamped(selection.range, toUTF16Length: field.textStorage.length)
        field.becomeFirstResponder()
    }
}

@MainActor private final class MarkdownTableCellTextView: UITextView {
    let position: MarkdownTableCellPosition
    var onTab: ((Bool) -> Void)?
    var layoutWidth: CGFloat = MarkdownTableColumnLayout.minimumColumnWidth
    private var lastLayoutWidth: CGFloat = 0

    init(position: MarkdownTableCellPosition) {
        self.position = position
        super.init(frame: .zero, textContainer: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight)
    }

    var measuredHeight: CGFloat {
        ceil(sizeThatFits(CGSize(width: layoutWidth, height: .greatestFiniteMagnitude)).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    override var undoManager: UndoManager? {
        var ancestor = superview
        while let view = ancestor {
            if let editor = view as? MarkdownTextView {
                return editor.undoManager
            }
            ancestor = view.superview
        }
        return super.undoManager
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tabForward)),
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(tabBackward)),
            UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(toggleStrong)),
            UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(toggleEmphasis)),
            UIKeyCommand(input: "x", modifierFlags: [.command, .shift], action: #selector(toggleStrikethrough))
        ]
    }

    @objc private func toggleStrong() {
        performMarkdownCommand(.toggleInline(.strong))
    }

    @objc private func toggleEmphasis() {
        performMarkdownCommand(.toggleInline(.emphasis))
    }

    @objc private func toggleStrikethrough() {
        performMarkdownCommand(.toggleInline(.strikethrough))
    }

    var markdownEditor: MarkdownTextView? {
        var ancestor = superview
        while let view = ancestor {
            if let editor = view as? MarkdownTextView {
                return editor
            }
            ancestor = view.superview
        }
        return nil
    }

    private func performMarkdownCommand(_ command: MarkdownEditorCommand) {
        markdownEditor?.perform(command)
    }

    @objc private func tabForward() {
        onTab?(false)
    }

    @objc private func tabBackward() {
        onTab?(true)
    }
}

#elseif canImport(AppKit)
/// Creates the AppKit view used to edit a `MarkdownTableAttachment`.
public final class MarkdownTableAttachmentViewProvider: NSTextAttachmentViewProvider {
    var availableWidth: CGFloat?

    override public func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        let width = markdownTableAvailableWidth(parentWidth: proposedLineFragment.width, textContainer: textContainer)
        guard let grid = view as? AppKitMarkdownTableGridView else {
            return .zero
        }
        let resolvedWidth = width ?? availableWidth
        return MainActor.assumeIsolated {
            grid.updateAvailableWidth(resolvedWidth)
            return CGRect(origin: .zero, size: grid.intrinsicContentSize)
        }
    }

    /// Creates the native AppKit table grid.
    override public func loadView() {
        guard let attachment = textAttachment as? MarkdownTableAttachment else {
            view = nil
            return
        }
        let controller = attachment.controller
        let maximumWidth = availableWidth
        let grid = MainActor.assumeIsolated {
            AppKitMarkdownTableGridView(controller: controller, maximumWidth: maximumWidth)
        }
        MainActor.assumeIsolated {
            let size = grid.intrinsicContentSize
            grid.frame.size = size
            grid.layoutSubtreeIfNeeded()
        }
        tracksTextAttachmentViewBounds = true
        view = grid
    }
}

@MainActor private final class AppKitMarkdownTableGridView: NSView, NSTextViewDelegate {
    private let controller: MarkdownTableController
    private var maximumWidth: CGFloat?
    private var gridView = NSGridView()
    private var fields: [MarkdownTableCellPosition: AppKitMarkdownTableCellTextView] = [:]
    private var columnWidthConstraints: [[NSLayoutConstraint]] = []
    private var isEditingCell = false

    init(controller: MarkdownTableController, maximumWidth: CGFloat?) {
        self.controller = controller
        self.maximumWidth = maximumWidth
        super.init(frame: .zero)
        rebuild()
        controller.onPresentationChange = { [weak self] in
            guard let self, !self.isEditingCell else {
                return
            }
            self.rebuild()
            self.resizeAttachment()
        }
        controller.onTypingAttributesChange = { [weak self] attributes in
            guard let self, let selection = self.controller.activeSelection else {
                return
            }
            guard let field = self.fields[selection.position] else {
                return
            }
            field.setSelectedRange(clamped(selection.range, toUTF16Length: field.string.utf16.count))
            self.window?.makeFirstResponder(field)
            field.typingAttributes = attributes
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        gridView.fittingSize
    }

    func textDidChange(_ notification: Notification) {
        guard let field = notification.object as? AppKitMarkdownTableCellTextView else {
            return
        }
        controller.activeTypingAttributes = field.typingAttributes
        controller.updateSelection(at: field.position, range: field.selectedRange())
        if !field.hasMarkedText() {
            isEditingCell = true
            controller.updateRichCell(at: field.position, text: field.attributedString())
            isEditingCell = false
        }
        updateColumnWidths()
        resizeAttachment()
    }

    func textDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? AppKitMarkdownTableCellTextView else {
            return
        }
        controller.activeTypingAttributes = field.typingAttributes
        controller.updateSelection(at: field.position, range: field.selectedRange())
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let field = notification.object as? AppKitMarkdownTableCellTextView,
              window?.firstResponder === field else {
            return
        }
        controller.activeTypingAttributes = field.typingAttributes
        controller.updateSelection(at: field.position, range: field.selectedRange())
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let field = textView as? AppKitMarkdownTableCellTextView else {
            return false
        }
        let destination: MarkdownTableCellPosition?
        switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                destination = controller.moveForward(from: field.position)
            case #selector(NSResponder.insertBacktab(_:)):
                destination = controller.moveBackward(from: field.position)
            default:
                return false
        }
        if let destination {
            rebuildIfNeededAndFocus(destination)
        }
        return true
    }

    private func rebuild() {
        gridView.removeFromSuperview()
        fields.removeAll()
        columnWidthConstraints.removeAll()
        let count = max(controller.columnCount, 1)
        var rows: [[NSView]] = []
        rows.append(makeRow(kind: .header, row: nil, columnCount: count))
        for row in controller.table.rows.indices {
            rows.append(makeRow(kind: .body, row: row, columnCount: count))
        }
        gridView = NSGridView(views: rows)
        gridView.rowSpacing = 0
        gridView.columnSpacing = 0
        gridView.xPlacement = .fill
        gridView.yPlacement = .fill
        updateColumnWidths()
        gridView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gridView)
        NSLayoutConstraint.activate([
            gridView.leadingAnchor.constraint(equalTo: leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: trailingAnchor),
            gridView.topAnchor.constraint(equalTo: topAnchor),
            gridView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        invalidateIntrinsicContentSize()
    }

    private func makeRow(kind: MarkdownTableRowKind, row: Int?, columnCount: Int) -> [NSView] {
        (0 ..< columnCount).map { column in
            let section: MarkdownTableCellPosition.Section = row.map { .body(row: $0) } ?? .header
            let position = MarkdownTableCellPosition(section: section, column: column)
            let field = AppKitMarkdownTableCellTextView(position: position)
            field.onContextSelection = { [weak controller] range in
                controller?.updateSelection(at: position, range: range)
            }
            field.textStorage?.setAttributedString(controller.richText(at: position))
            field.alignment = controller.alignment(at: position)
            field.delegate = self
            field.typingAttributes = [.font: NSFont.preferredFont(forTextStyle: .body)]
            field.backgroundColor = kind == .header ? .controlBackgroundColor : .textBackgroundColor
            field.drawsBackground = true
            field.isRichText = true
            field.allowsUndo = false
            field.isHorizontallyResizable = false
            field.isVerticallyResizable = true
            field.textContainerInset = NSSize(width: 8, height: 4)
            field.textContainer?.lineFragmentPadding = 0
            field.textContainer?.widthTracksTextView = true
            field.wantsLayer = true
            field.layer?.borderColor = NSColor.gridColor.cgColor
            field.layer?.borderWidth = 0.5
            field.setAccessibilityLabel(kind == .header ? "Table header, column \(column + 1)" : "Table row \((row ?? 0) + 1), column \(column + 1)")
            fields[position] = field
            let widthConstraint = field.widthAnchor.constraint(equalToConstant: MarkdownTableColumnLayout.minimumColumnWidth)
            widthConstraint.isActive = true
            if columnWidthConstraints.indices.contains(column) {
                columnWidthConstraints[column].append(widthConstraint)
            } else {
                columnWidthConstraints.append([widthConstraint])
            }
            return field
        }
    }

    private func updateColumnWidths() {
        let columnCount = max(controller.columnCount, 1)
        let preferredWidths = (0 ..< columnCount).map { column in
            fields
                .filter { $0.key.column == column }
                .map { _, field in
                    let textWidth = field.attributedString().size().width
                    return ceil(textWidth) + 16
                }
                .max() ?? MarkdownTableColumnLayout.minimumColumnWidth
        }
        let widths = MarkdownTableColumnLayout.widths(
            preferredWidths: preferredWidths,
            availableWidth: maximumWidth
        )
        guard gridView.numberOfColumns == widths.count else {
            return
        }
        for column in widths.indices {
            gridView.column(at: column).width = widths[column]
            for constraint in columnWidthConstraints[column] {
                constraint.constant = widths[column]
            }
            for field in fields where field.key.column == column {
                field.value.layoutWidth = widths[column]
                field.value.invalidateIntrinsicContentSize()
            }
        }
        needsLayout = true
    }

    func updateAvailableWidth(_ width: CGFloat?) {
        guard maximumWidth != width else {
            return
        }
        maximumWidth = width
        updateColumnWidths()
        resizeAttachment()
    }

    private func resizeAttachment() {
        invalidateIntrinsicContentSize()
        let size = intrinsicContentSize
        if frame.size != size {
            frame.size = size
        }
    }

    private func rebuildIfNeededAndFocus(_ position: MarkdownTableCellPosition) {
        if fields[position] == nil {
            rebuild()
        }
        guard let field = fields[position] else {
            return
        }
        field.setSelectedRange(NSRange(location: 0, length: 0))
        controller.updateSelection(at: position, range: field.selectedRange())
        window?.makeFirstResponder(field)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let selection = controller.activeSelection,
              let field = fields[selection.position] else {
            return
        }
        field.setSelectedRange(clamped(selection.range, toUTF16Length: field.string.utf16.count))
        window?.makeFirstResponder(field)
    }
}

@MainActor private final class AppKitMarkdownTableCellTextView: NSTextView {
    let position: MarkdownTableCellPosition
    var onContextSelection: ((NSRange) -> Void)?
    var layoutWidth: CGFloat = MarkdownTableColumnLayout.minimumColumnWidth
    private let cellTextStorage: NSTextStorage

    init(position: MarkdownTableCellPosition) {
        self.position = position
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer()
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        self.cellTextStorage = textStorage
        super.init(frame: .zero, textContainer: textContainer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if window?.firstResponder !== self {
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)), length: 0))
            window?.makeFirstResponder(self)
        }
        let selection = selectedRange()
        let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        if selection.length > 0 {
            setSelectedRange(selection)
        }
        guard let editor = markdownEditor else {
            return menu
        }
        onContextSelection?(selectedRange())
        let groups = [
            ("Style", selectedRange().length > 0 ? MarkdownEditorCommand.contextualInlineCommands : []),
            ("Table", tableContextCommands)
        ]
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        for (title, commands) in groups where !commands.isEmpty {
            let submenu = NSMenu(title: title)
            submenu.autoenablesItems = false
            for (title, command) in commands {
                let item = NSMenuItem(title: title, action: #selector(performContextCommand(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = command
                item.isEnabled = editor.canPerform(command)
                submenu.addItem(item)
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }

    private var markdownEditor: MarkdownTextView? {
        var ancestor = superview
        while let view = ancestor {
            if let editor = view as? MarkdownTextView {
                return editor
            }
            ancestor = view.superview
        }
        return nil
    }

    @objc private func performContextCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? MarkdownEditorCommand else {
            return
        }
        window?.makeFirstResponder(self)
        onContextSelection?(selectedRange())
        markdownEditor?.perform(command)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let style: MarkdownInlineStyle? = switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
            case ("b", .command): .strong
            case ("i", .command): .emphasis
            case ("x", [.command, .shift]): .strikethrough
            default: nil
        }
        if let style {
            var ancestor = superview
            while let view = ancestor {
                if let editor = view as? MarkdownTextView {
                    editor.perform(.toggleInline(style)); return true
                }
                ancestor = view.superview
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override var intrinsicContentSize: NSSize {
        let bounds = attributedString().boundingRect(
            with: NSSize(width: max(1, layoutWidth - 16), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return NSSize(width: NSView.noIntrinsicMetric, height: max(ceil(bounds.height) + 8, 28))
    }
}
#endif
