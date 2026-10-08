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

/// The cells a table mutation changed, so a grid can update only those cells.
enum MarkdownTablePresentationChange: Equatable {
    case cell(MarkdownTableCellPosition)
    case insertedRow(Int)
    case removedRow(Int)
    case insertedColumn(Int)
    case removedColumn(Int)
    case reload

    /// The one cell, row, or column change that turns `old` into `new`, or `.reload`.
    static func difference(from old: MarkdownTable, to new: MarkdownTable) -> Self {
        guard old.isRectangular, new.isRectangular else {
            return .reload
        }
        switch (new.rows.count - old.rows.count, new.alignments.count - old.alignments.count) {
            case (0, 0):
                guard old.alignments == new.alignments else {
                    return .reload
                }
                let rows = [old.header] + old.rows
                let changed = zip(rows, [new.header] + new.rows).enumerated().flatMap { row, pair in
                    pair.0.cells.indices.filter { pair.0.cells[$0] != pair.1.cells[$0] }.map { column in
                        MarkdownTableCellPosition(section: row == 0 ? .header : .body(row: row - 1), column: column)
                    }
                }
                return changed.count == 1 ? .cell(changed[0]) : .reload
            case (1, 0) where old.header == new.header && old.alignments == new.alignments:
                return insertedIndex(in: new.rows, comparedTo: old.rows).map(insertedRow) ?? .reload
            case (-1, 0) where old.header == new.header && old.alignments == new.alignments:
                return insertedIndex(in: old.rows, comparedTo: new.rows).map(removedRow) ?? .reload
            case (0, 1):
                return insertedIndex(in: new.columns, comparedTo: old.columns).map(insertedColumn) ?? .reload
            case (0, -1):
                return insertedIndex(in: old.columns, comparedTo: new.columns).map(removedColumn) ?? .reload
            default:
                return .reload
        }
    }

    /// The index of the one element `longer` adds to `shorter`, if that is their only difference.
    private static func insertedIndex<Element: Equatable>(in longer: [Element], comparedTo shorter: [Element]) -> Int? {
        let index = zip(longer, shorter).prefix { $0 == $1 }.count
        guard longer.count == shorter.count + 1,
              longer[(index + 1)...].elementsEqual(shorter[index...]) else {
            return nil
        }
        return index
    }
}

private struct MarkdownTableColumn: Equatable {
    var alignment: MarkdownTableAlignment
    var cells: [MarkdownTableCell]
}

private extension MarkdownTable {
    /// Whether every row has one cell per column, as grids show it.
    var isRectangular: Bool {
        !alignments.isEmpty && header.cells.count == alignments.count
            && rows.allSatisfy { $0.cells.count == alignments.count }
    }

    var columns: [MarkdownTableColumn] {
        alignments.indices.map { column in
            MarkdownTableColumn(alignment: alignments[column], cells: [header.cells[column]] + rows.map { $0.cells[column] })
        }
    }
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
    var onPresentationChange: ((MarkdownTablePresentationChange) -> Void)?
    var activeTypingAttributes: [NSAttributedString.Key: Any] = [:]
    var onTypingAttributesChange: (([NSAttributedString.Key: Any]) -> Void)?
    /// Focuses the active selection's cell in a grid that stayed on screen.
    var onFocusRequest: (() -> Void)?
    /// Whether a presented table still needs its owner's cell selection focused.
    private var needsFocusAfterPresentation = false
    /// Cells whose text is replaced move their carets, which is not a user selection.
    private var isPresenting = false
    /// The grid most recently loaded for this table and the layout showing it.
    private var loadedGrid: (view: AnyObject, textLayoutManager: ObjectIdentifier)?

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
        focusAfterPresentation()
    }

    /// Returns the grid last loaded for this table into a text layout manager, or a new one.
    ///
    /// TextKit loads a new view whenever an attachment's text is replaced, even
    /// with the same attachment, so an unchanged table kept by a projection
    /// update keeps its grid, measured cells, and editing state.
    func grid<Grid: AnyObject>(in textLayoutManager: ObjectIdentifier?, make: () -> Grid) -> Grid {
        guard let textLayoutManager else {
            return make()
        }
        if let loadedGrid, loadedGrid.textLayoutManager == textLayoutManager, let grid = loadedGrid.view as? Grid {
            return grid
        }
        let grid = make()
        loadedGrid = (grid, textLayoutManager)
        return grid
    }

    /// Shows a table its document owner changed, as after a table command or undo,
    /// updating only the cells that differ. The owner already has the table, so the
    /// change is not reported, and the owner sets the cell selection afterward.
    func present(_ updated: MarkdownTable) {
        let change = MarkdownTablePresentationChange.difference(from: table, to: updated)
        activeSelection = nil
        table = updated
        isPresenting = true
        onPresentationChange?(change)
        isPresenting = false
        needsFocusAfterPresentation = true
    }

    /// Replaces the remembered nested selection without reporting it.
    func restoreSelection(_ selection: MarkdownTableCellSelection?) {
        activeSelection = selection
        focusAfterPresentation()
    }

    /// A new grid focuses the selected cell when it enters the window, so a kept
    /// grid does once its owner sets the selection.
    private func focusAfterPresentation() {
        guard needsFocusAfterPresentation else {
            return
        }
        needsFocusAfterPresentation = false
        onFocusRequest?()
    }

    func updateSelection(at position: MarkdownTableCellPosition, range: NSRange) {
        let selection = MarkdownTableCellSelection(position: position, range: range)
        guard !isPresenting, selection != activeSelection else {
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
        max(1, table.alignments.count, table.header.cells.count, table.rows.lazy.map(\.cells.count).max() ?? 0)
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
        notifyChange(.cell(position))
    }

    /// Returns the next editable cell in reading order, appending a row at the end.
    @discardableResult public func moveForward(from position: MarkdownTableCellPosition) -> MarkdownTableCellPosition? {
        let count = columnCount
        guard position.column >= 0, position.column < count else {
            return .init(section: .header, column: 0)
        }
        if case let .body(row) = position.section, !table.rows.indices.contains(row) {
            return .init(section: .header, column: 0)
        }
        if position.column + 1 < count {
            return .init(section: position.section, column: position.column + 1)
        }
        let nextRow = switch position.section {
            case .header: 0
            case let .body(row): row + 1
        }
        if nextRow == table.rows.count {
            appendRow()
        }
        return .init(section: .body(row: nextRow), column: 0)
    }

    /// Returns the preceding editable cell in reading order.
    public func moveBackward(from position: MarkdownTableCellPosition) -> MarkdownTableCellPosition? {
        let count = columnCount
        guard position.column >= 0, position.column < count else {
            return nil
        }
        if case let .body(row) = position.section, !table.rows.indices.contains(row) {
            return nil
        }
        if position.column > 0 {
            return .init(section: position.section, column: position.column - 1)
        }
        switch position.section {
            case .header:
                return nil
            case .body(row: 0):
                return .init(section: .header, column: count - 1)
            case let .body(row):
                return .init(section: .body(row: row - 1), column: count - 1)
        }
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
        notifyChange(.insertedRow(table.rows.count - 1))
    }

    /// Inserts an empty body row at a zero-based index.
    public func insertRow(at index: Int) {
        guard index >= 0, index <= table.rows.count else {
            return
        }
        let count = max(columnCount, 1)
        ensureColumnCount(atLeast: count)
        table.rows.insert(MarkdownTableRow(cells: emptyCells(count: count)), at: index)
        notifyChange(.insertedRow(index))
    }

    /// Deletes the body row at a zero-based index.
    public func deleteRow(at index: Int) {
        guard table.rows.indices.contains(index) else {
            return
        }
        table.rows.remove(at: index)
        notifyChange(.removedRow(index))
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
        notifyChange(.insertedColumn(index))
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
        notifyChange(.removedColumn(index))
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

    private func notifyChange(_ change: MarkdownTablePresentationChange = .reload) {
        onPresentationChange?(change)
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
            let content = cell(at: position)?.content ?? []
            let isHeader = position.section == .header
            let alignment = alignment(at: position)
            return MarkdownTableCellTextCache.text(for: content, isHeader: isHeader, alignment: alignment) {
                Self.projectRichText(content, isHeader: isHeader, alignment: alignment)
            }
        }

        private static func projectRichText(_ content: [MarkdownInline], isHeader: Bool, alignment: NSTextAlignment) -> NSAttributedString {
            let content = content.map(MarkdownTableCellSourceCodec.editableInline)
            let projection = MarkdownProjectionBuilder().build(document: MarkdownDocument(blocks: [.paragraph(content)]))
            let result = NSMutableAttributedString(attributedString: projection.attributedString)
            if result.string.hasSuffix("\n") {
                result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
            }
            if isHeader {
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
            paragraph.alignment = alignment
            result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
            return NSAttributedString(attributedString: result)
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

    /// Keeps projected cell text by content and style. Every cell is projected when a
    /// grid loads, including the grid for a table a command changed, whose cells are
    /// mostly unchanged.
    @MainActor enum MarkdownTableCellTextCache {
        private struct Key: Hashable {
            var content: [MarkdownInline]
            var isHeader: Bool
            var alignment: NSTextAlignment
            // Theme fonts derive from the body font, which follows Dynamic Type.
            #if canImport(UIKit)
                var bodyFont = UIFont.preferredFont(forTextStyle: .body)
            #elseif canImport(AppKit)
                var bodyFont = NSFont.preferredFont(forTextStyle: .body)
            #endif
        }

        /// The number of texts kept before the cache starts over.
        static let capacity = 512
        private static var texts: [Key: NSAttributedString] = [:]

        static func text(
            for content: [MarkdownInline],
            isHeader: Bool,
            alignment: NSTextAlignment,
            project: () -> NSAttributedString
        ) -> NSAttributedString {
            let key = Key(content: content, isHeader: isHeader, alignment: alignment)
            if let text = texts[key] {
                return text
            }
            if texts.count >= capacity {
                texts.removeAll(keepingCapacity: true)
            }
            let text = project()
            texts[key] = text
            return text
        }
    }

    /// Retains cell measurements between native edits. Width changes can affect other
    /// columns when the table is constrained, so resolve all columns from cached maxima.
    struct MarkdownTableCellLayoutCache {
        private var positionsByColumn: [[MarkdownTableCellPosition]]
        private var preferredCellWidths: [MarkdownTableCellPosition: CGFloat] = [:]
        private var preferredColumnWidths: [CGFloat]
        private(set) var widths: [CGFloat] = []

        init(positions: [MarkdownTableCellPosition], columnCount: Int) {
            var columns = Array(repeating: [MarkdownTableCellPosition](), count: columnCount)
            for position in positions {
                columns[position.column].append(position)
            }
            positionsByColumn = columns
            preferredColumnWidths = Array(repeating: MarkdownTableColumnLayout.minimumColumnWidth, count: columnCount)
        }

        /// Carries measurements over after rows or columns were inserted or removed.
        ///
        /// `previousPositions` maps each kept cell to its former position and
        /// `previousColumns` each column to its former index, or nil for a new column.
        /// New cells have no measurement until they are passed to the next update.
        mutating func reindex(
            positions: [MarkdownTableCellPosition],
            columnCount: Int,
            previousPositions: [MarkdownTableCellPosition: MarkdownTableCellPosition],
            previousColumns: [Int?]
        ) {
            var columns = Array(repeating: [MarkdownTableCellPosition](), count: columnCount)
            var cellWidths: [MarkdownTableCellPosition: CGFloat] = [:]
            for position in positions {
                columns[position.column].append(position)
                if let previous = previousPositions[position], let width = preferredCellWidths[previous] {
                    cellWidths[position] = width
                }
            }
            positionsByColumn = columns
            preferredCellWidths = cellWidths
            preferredColumnWidths = columns.map { column in
                column.compactMap { cellWidths[$0] }.max() ?? MarkdownTableColumnLayout.minimumColumnWidth
            }
            // New columns have no resolved width yet, so the next update lays out their cells.
            widths = previousColumns.map { previous in
                previous.flatMap { widths.indices.contains($0) ? widths[$0] : nil } ?? -1
            }
        }

        /// Returns only cells whose content or resolved column width needs layout.
        /// Nil changed cells refresh every measurement after a configuration change.
        mutating func update(
            changedCells: [MarkdownTableCellPosition]? = nil,
            availableWidth: CGFloat?,
            measure: (MarkdownTableCellPosition) -> CGFloat
        ) -> Set<MarkdownTableCellPosition> {
            let measuredPositions = changedCells ?? positionsByColumn.flatMap(\.self)
            for position in measuredPositions {
                preferredCellWidths[position] = measure(position)
            }
            let changedColumns = changedCells.map { Set($0.map(\.column)).sorted() } ?? Array(positionsByColumn.indices)
            for column in changedColumns {
                preferredColumnWidths[column] = positionsByColumn[column]
                    .compactMap { preferredCellWidths[$0] }.max() ?? MarkdownTableColumnLayout.minimumColumnWidth
            }
            let resolvedWidths = MarkdownTableColumnLayout.widths(
                preferredWidths: preferredColumnWidths,
                availableWidth: availableWidth
            )
            var affected = Set(measuredPositions)
            for column in resolvedWidths.indices where !widths.indices.contains(column) || widths[column] != resolvedWidths[column] {
                affected.formUnion(positionsByColumn[column])
            }
            widths = resolvedWidths
            return affected
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
            guard overflow > 0.001 else {
                return widths
            }
            let descendingColumns = widths.indices.sorted { preferred[$0] > preferred[$1] }
            var widest = preferred[descendingColumns[0]]
            var activeCount = 0
            var leveledCount = 0
            while overflow > 0.001 {
                while activeCount < descendingColumns.count,
                      abs(preferred[descendingColumns[activeCount]] - widest) < 0.001 {
                    activeCount += 1
                }
                let nextWidth = activeCount < descendingColumns.count
                    ? preferred[descendingColumns[activeCount]] : minimum
                let lowerBound = max(nextWidth, minimum)
                let reducible = (widest - lowerBound) * CGFloat(activeCount)
                if reducible >= overflow {
                    let reduction = overflow / CGFloat(activeCount)
                    for position in 0 ..< activeCount {
                        let column = descendingColumns[position]
                        // Newly joined widths retain their sub-tolerance differences
                        // unless the whole group reached a lower plateau previously.
                        widths[column] = (position < leveledCount ? widest : preferred[column]) - reduction
                    }
                    return widths
                }
                // Track complete plateau reductions without rewriting the prefix on
                // every step. Each column joins the active prefix only once.
                widest = lowerBound
                leveledCount = activeCount
                overflow -= reducible
            }
            for position in 0 ..< leveledCount {
                widths[descendingColumns[position]] = widest
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

    private func markdownTableAccessibilityLabel(for position: MarkdownTableCellPosition) -> String {
        switch position.section {
            case .header: "Table header, column \(position.column + 1)"
            case let .body(row): "Table row \(row + 1), column \(position.column + 1)"
        }
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

        /// The editor path reported by table callbacks, updated when earlier blocks change.
        @MainActor var pathReference: EditorPathReference?

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
            let textLayoutManager = textLayoutManager.map(ObjectIdentifier.init)
            let grid = MainActor.assumeIsolated {
                controller.grid(in: textLayoutManager) {
                    UIKitMarkdownTableGridView(controller: controller, maximumWidth: maximumWidth)
                }
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

    @MainActor final class UIKitMarkdownTableGridView: UIView, UITextViewDelegate {
        private(set) var attachmentResizeCount = 0
        /// Character range whose layout the most recent resize invalidated.
        private(set) var invalidatedAttachmentRange: NSRange?
        private let controller: MarkdownTableController
        private var maximumWidth: CGFloat?
        private let stack = UIStackView()
        private var fields: [MarkdownTableCellPosition: MarkdownTableCellTextView] = [:]
        private var columnWidthConstraints: [[NSLayoutConstraint]] = []
        private var isEditingCell = false
        private var rowStacks: [MarkdownTableRowStackView] = []
        private var cellLayout = MarkdownTableCellLayoutCache(positions: [], columnCount: 0)
        private var cellHeights: [MarkdownTableCellPosition: CGFloat] = [:]

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
            controller.onPresentationChange = { [weak self] change in
                guard let self, !self.isEditingCell else {
                    return
                }
                self.apply(change)
                self.resizeAttachment()
            }
            controller.onFocusRequest = { [weak self] in
                self?.focusActiveSelection()
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
            if updateColumnWidths(changedCells: [field.position]) {
                resizeAttachment()
            }
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
            cellHeights.removeAll()
            let count = max(controller.columnCount, 1)
            columnWidthConstraints = Array(repeating: [], count: count)
            for row in -1 ..< controller.table.rows.count {
                let rowStack = makeRow(section: row < 0 ? .header : .body(row: row), columnCount: count)
                stack.addArrangedSubview(rowStack)
                rowStacks.append(rowStack)
            }
            for case let field as MarkdownTableCellTextView in rowStacks.flatMap(\.arrangedSubviews) {
                fields[field.position] = field
                columnWidthConstraints[field.position.column].append(field.widthConstraint)
            }
            cellLayout = MarkdownTableCellLayoutCache(positions: Array(fields.keys), columnCount: count)
            updateColumnWidths()
        }

        /// Updates only the cells a table mutation changed, rebuilding when the change
        /// does not describe the difference between the grid and the table.
        private func apply(_ change: MarkdownTablePresentationChange) {
            let columnCount = columnWidthConstraints.count
            let rowCount = rowStacks.count
            let rowDelta = controller.table.rows.count + 1 - rowCount
            let columnDelta = max(controller.columnCount, 1) - columnCount
            switch change {
                case let .cell(position) where rowDelta == 0 && columnDelta == 0 && fields[position] != nil:
                    if let field = fields[position] {
                        configureText(of: field)
                    }
                    updateColumnWidths(changedCells: [position])
                case let .insertedRow(row) where rowDelta == 1 && columnDelta == 0 && row >= 0 && row < rowCount:
                    let rowStack = makeRow(section: .body(row: row), columnCount: columnCount)
                    stack.insertArrangedSubview(rowStack, at: row + 1)
                    rowStacks.insert(rowStack, at: row + 1)
                    reindex(previousColumns: Array(0 ..< columnCount))
                case let .removedRow(row) where rowDelta == -1 && columnDelta == 0 && row >= 0 && row + 1 < rowCount:
                    rowStacks.remove(at: row + 1).removeFromSuperview()
                    reindex(previousColumns: Array(0 ..< columnCount))
                case let .insertedColumn(column) where rowDelta == 0 && columnDelta == 1 && column >= 0 && column <= columnCount:
                    for (row, rowStack) in rowStacks.enumerated() {
                        let section: MarkdownTableCellPosition.Section = row == 0 ? .header : .body(row: row - 1)
                        rowStack.insertArrangedSubview(makeField(at: MarkdownTableCellPosition(section: section, column: column)), at: column)
                    }
                    reindex(previousColumns: (0 ... columnCount).map { $0 < column ? $0 : $0 == column ? nil : $0 - 1 })
                case let .removedColumn(column) where rowDelta == 0 && columnDelta == -1 && column >= 0 && column < columnCount:
                    for rowStack in rowStacks {
                        rowStack.arrangedSubviews[column].removeFromSuperview()
                    }
                    reindex(previousColumns: (0 ..< columnCount - 1).map { $0 < column ? $0 : $0 + 1 })
                default:
                    rebuild()
            }
        }

        /// Renumbers cells after rows or columns were inserted or removed, keeping the
        /// measurements of moved cells and measuring only the new ones.
        private func reindex(previousColumns: [Int?]) {
            var updatedFields: [MarkdownTableCellPosition: MarkdownTableCellTextView] = [:]
            var previousPositions: [MarkdownTableCellPosition: MarkdownTableCellPosition] = [:]
            var updatedHeights: [MarkdownTableCellPosition: CGFloat] = [:]
            var newCells: [MarkdownTableCellPosition] = []
            columnWidthConstraints = Array(repeating: [], count: previousColumns.count)
            for (row, rowStack) in rowStacks.enumerated() {
                let section: MarkdownTableCellPosition.Section = row == 0 ? .header : .body(row: row - 1)
                for case let (column, field as MarkdownTableCellTextView) in rowStack.arrangedSubviews.enumerated() {
                    let position = MarkdownTableCellPosition(section: section, column: column)
                    if fields[field.position] === field {
                        previousPositions[position] = field.position
                        updatedHeights[position] = cellHeights[field.position]
                        if controller.activeSelection?.position == field.position, field.position != position {
                            controller.updateSelection(at: position, range: field.selectedRange)
                        }
                    } else {
                        newCells.append(position)
                    }
                    field.position = position
                    field.accessibilityLabel = markdownTableAccessibilityLabel(for: position)
                    updatedFields[position] = field
                    columnWidthConstraints[column].append(field.widthConstraint)
                }
            }
            fields = updatedFields
            cellHeights = updatedHeights
            cellLayout.reindex(
                positions: Array(updatedFields.keys),
                columnCount: previousColumns.count,
                previousPositions: previousPositions,
                previousColumns: previousColumns
            )
            updateColumnWidths(changedCells: newCells, remeasuringAllRows: true)
        }

        private func makeRow(section: MarkdownTableCellPosition.Section, columnCount: Int) -> MarkdownTableRowStackView {
            let rowStack = MarkdownTableRowStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 0
            rowStack.distribution = .fill
            for column in 0 ..< columnCount {
                rowStack.addArrangedSubview(makeField(at: MarkdownTableCellPosition(section: section, column: column)))
            }
            rowStack.heightConstraint.isActive = true
            return rowStack
        }

        private func makeField(at position: MarkdownTableCellPosition) -> MarkdownTableCellTextView {
            let field = MarkdownTableCellTextView(position: position)
            configureText(of: field)
            field.delegate = self
            field.layer.borderColor = UIColor.opaqueSeparator.cgColor
            field.layer.borderWidth = 1 / UIScreen.main.scale
            field.backgroundColor = position.section == .header ? .secondarySystemBackground : .systemBackground
            field.isScrollEnabled = false
            field.textContainerInset = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
            field.textContainer.lineFragmentPadding = 0
            field.setContentHuggingPriority(.required, for: .vertical)
            field.accessibilityLabel = markdownTableAccessibilityLabel(for: position)
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
            field.widthConstraint.isActive = true
            return field
        }

        /// Sets a cell's text the same way for new and updated cells.
        private func configureText(of field: MarkdownTableCellTextView) {
            field.attributedText = controller.richText(at: field.position)
            field.textAlignment = controller.alignment(at: field.position)
            field.typingAttributes = [.font: UIFont.preferredFont(forTextStyle: .body)]
        }

        /// Lays out changed cells, or every cell when nil. Removing cells can lower
        /// any row's height, so structural changes check every row.
        @discardableResult private func updateColumnWidths(
            changedCells: [MarkdownTableCellPosition]? = nil,
            remeasuringAllRows: Bool = false
        ) -> Bool {
            let fields = self.fields
            let previousWidths = cellLayout.widths
            let affected = cellLayout.update(changedCells: changedCells, availableWidth: maximumWidth) { position in
                guard let field = fields[position] else {
                    return MarkdownTableColumnLayout.minimumColumnWidth
                }
                return ceil(field.attributedText.size().width) + field.textContainerInset.left + field.textContainerInset.right + 2
            }
            let widths = cellLayout.widths
            for column in widths.indices where !previousWidths.indices.contains(column) || previousWidths[column] != widths[column] {
                for constraint in columnWidthConstraints[column] where constraint.constant != widths[column] {
                    constraint.constant = widths[column]
                }
            }
            var affectedRows = remeasuringAllRows ? Set(rowStacks.indices) : []
            for position in affected {
                guard let field = fields[position] else {
                    continue
                }
                // Cells inserted into an existing column take its width here.
                if field.widthConstraint.constant != widths[position.column] {
                    field.widthConstraint.constant = widths[position.column]
                }
                field.layoutWidth = widths[position.column]
                let height = field.measuredHeight
                if cellHeights[position] != height {
                    cellHeights[position] = height
                    field.invalidateIntrinsicContentSize()
                }
                let row = switch position.section {
                    case .header: 0
                    case let .body(row): row + 1
                }
                affectedRows.insert(row)
            }
            var heightChanged = false
            for row in affectedRows {
                let section: MarkdownTableCellPosition.Section = row == 0 ? .header : .body(row: row - 1)
                let height = widths.indices.compactMap { cellHeights[.init(section: section, column: $0)] }.max() ?? 28
                if rowStacks[row].heightConstraint.constant != height {
                    rowStacks[row].heightConstraint.constant = height
                    heightChanged = true
                }
            }
            let dimensionsChanged = previousWidths != widths || heightChanged
            if dimensionsChanged {
                setNeedsLayout()
            }
            return dimensionsChanged
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
            attachmentResizeCount += 1
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
                            invalidateAttachmentLayout(in: editor, manager: manager)
                        }
                        editor.setNeedsLayout()
                        break
                    }
                    ancestor = view.superview
                }
            }
        }

        /// Invalidates only the fragment holding this table; later fragments move during relayout.
        private func invalidateAttachmentLayout(in editor: MarkdownTextView, manager: NSTextLayoutManager) {
            let storage = editor.textStorage
            var attachmentRange: NSRange?
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                if (value as? MarkdownTableAttachment)?.controller === controller {
                    attachmentRange = NSRange(location: range.location, length: 1)
                    stop.pointee = true
                }
            }
            guard let attachmentRange,
                  let contentManager = manager.textContentManager,
                  let start = contentManager.location(manager.documentRange.location, offsetBy: attachmentRange.location),
                  let end = contentManager.location(start, offsetBy: attachmentRange.length),
                  let textRange = NSTextRange(location: start, end: end) else {
                invalidatedAttachmentRange = nil
                manager.invalidateLayout(for: manager.documentRange)
                return
            }
            invalidatedAttachmentRange = attachmentRange
            manager.invalidateLayout(for: textRange)
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
            focusActiveSelection()
        }

        private func focusActiveSelection() {
            guard let selection = controller.activeSelection,
                  let field = fields[selection.position] else {
                return
            }
            field.selectedRange = clamped(selection.range, toUTF16Length: field.textStorage.length)
            field.becomeFirstResponder()
        }
    }

    @MainActor private final class MarkdownTableRowStackView: UIStackView {
        private(set) lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 28)
    }

    @MainActor private final class MarkdownTableCellTextView: UITextView {
        var position: MarkdownTableCellPosition
        var onTab: ((Bool) -> Void)?
        var layoutWidth: CGFloat = MarkdownTableColumnLayout.minimumColumnWidth
        private(set) lazy var widthConstraint = widthAnchor.constraint(equalToConstant: MarkdownTableColumnLayout.minimumColumnWidth)
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
            let textLayoutManager = textLayoutManager.map(ObjectIdentifier.init)
            let grid = MainActor.assumeIsolated {
                controller.grid(in: textLayoutManager) {
                    AppKitMarkdownTableGridView(controller: controller, maximumWidth: maximumWidth)
                }
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

    @MainActor final class AppKitMarkdownTableGridView: NSView, NSTextViewDelegate {
        private(set) var attachmentResizeCount = 0
        private let controller: MarkdownTableController
        private var maximumWidth: CGFloat?
        private var gridView = NSGridView()
        private var fields: [MarkdownTableCellPosition: AppKitMarkdownTableCellTextView] = [:]
        private var columnWidthConstraints: [[NSLayoutConstraint]] = []
        private var isEditingCell = false
        private var cellLayout = MarkdownTableCellLayoutCache(positions: [], columnCount: 0)
        private var cellHeights: [MarkdownTableCellPosition: CGFloat] = [:]
        private var rowHeights: [MarkdownTableCellPosition.Section: CGFloat] = [:]

        init(controller: MarkdownTableController, maximumWidth: CGFloat?) {
            self.controller = controller
            self.maximumWidth = maximumWidth
            super.init(frame: .zero)
            rebuild()
            controller.onPresentationChange = { [weak self] change in
                guard let self, !self.isEditingCell else {
                    return
                }
                self.apply(change)
                self.resizeAttachment()
            }
            controller.onFocusRequest = { [weak self] in
                self?.focusActiveSelection()
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
            if updateColumnWidths(changedCells: [field.position]) {
                resizeAttachment()
            }
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
            cellHeights.removeAll()
            rowHeights.removeAll()
            let count = max(controller.columnCount, 1)
            var rows: [[NSView]] = []
            rows.append(makeRow(section: .header, columnCount: count))
            for row in controller.table.rows.indices {
                rows.append(makeRow(section: .body(row: row), columnCount: count))
            }
            columnWidthConstraints = Array(repeating: [], count: count)
            for case let field as AppKitMarkdownTableCellTextView in rows.joined() {
                fields[field.position] = field
                columnWidthConstraints[field.position.column].append(field.widthConstraint)
            }
            gridView = NSGridView(views: rows)
            gridView.rowSpacing = 0
            gridView.columnSpacing = 0
            gridView.xPlacement = .fill
            gridView.yPlacement = .fill
            cellLayout = MarkdownTableCellLayoutCache(positions: Array(fields.keys), columnCount: count)
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

        /// Updates only the cells a table mutation changed, rebuilding when the change
        /// does not describe the difference between the grid and the table.
        private func apply(_ change: MarkdownTablePresentationChange) {
            let columnCount = gridView.numberOfColumns
            let rowCount = gridView.numberOfRows
            let rowDelta = controller.table.rows.count + 1 - rowCount
            let columnDelta = max(controller.columnCount, 1) - columnCount
            switch change {
                case let .cell(position) where rowDelta == 0 && columnDelta == 0 && fields[position] != nil:
                    if let field = fields[position] {
                        configureText(of: field)
                    }
                    updateColumnWidths(changedCells: [position])
                case let .insertedRow(row) where rowDelta == 1 && columnDelta == 0 && row >= 0 && row < rowCount:
                    gridView.insertRow(at: row + 1, with: makeRow(section: .body(row: row), columnCount: columnCount))
                    reindex(previousColumns: Array(0 ..< columnCount))
                case let .removedRow(row) where rowDelta == -1 && columnDelta == 0 && row >= 0 && row + 1 < rowCount:
                    let removed = gridView.row(at: row + 1)
                    let views = (0 ..< columnCount).compactMap { removed.cell(at: $0).contentView }
                    gridView.removeRow(at: row + 1)
                    views.forEach { $0.removeFromSuperview() }
                    reindex(previousColumns: Array(0 ..< columnCount))
                case let .insertedColumn(column) where rowDelta == 0 && columnDelta == 1 && column >= 0 && column <= columnCount:
                    let views = (0 ..< rowCount).map { row in
                        makeField(at: MarkdownTableCellPosition(section: row == 0 ? .header : .body(row: row - 1), column: column))
                    }
                    gridView.insertColumn(at: column, with: views)
                    reindex(previousColumns: (0 ... columnCount).map { $0 < column ? $0 : $0 == column ? nil : $0 - 1 })
                case let .removedColumn(column) where rowDelta == 0 && columnDelta == -1 && column >= 0 && column < columnCount:
                    let removed = gridView.column(at: column)
                    let views = (0 ..< rowCount).compactMap { removed.cell(at: $0).contentView }
                    gridView.removeColumn(at: column)
                    views.forEach { $0.removeFromSuperview() }
                    reindex(previousColumns: (0 ..< columnCount - 1).map { $0 < column ? $0 : $0 + 1 })
                default:
                    rebuild()
            }
        }

        /// Renumbers cells after rows or columns were inserted or removed, keeping the
        /// measurements of moved cells and measuring only the new ones.
        private func reindex(previousColumns: [Int?]) {
            var updatedFields: [MarkdownTableCellPosition: AppKitMarkdownTableCellTextView] = [:]
            var previousPositions: [MarkdownTableCellPosition: MarkdownTableCellPosition] = [:]
            var updatedHeights: [MarkdownTableCellPosition: CGFloat] = [:]
            var newCells: [MarkdownTableCellPosition] = []
            columnWidthConstraints = Array(repeating: [], count: previousColumns.count)
            for row in 0 ..< gridView.numberOfRows {
                let section: MarkdownTableCellPosition.Section = row == 0 ? .header : .body(row: row - 1)
                for column in 0 ..< gridView.numberOfColumns {
                    guard let field = gridView.cell(atColumnIndex: column, rowIndex: row).contentView as? AppKitMarkdownTableCellTextView else {
                        continue
                    }
                    let position = MarkdownTableCellPosition(section: section, column: column)
                    if fields[field.position] === field {
                        previousPositions[position] = field.position
                        updatedHeights[position] = cellHeights[field.position]
                        if controller.activeSelection?.position == field.position, field.position != position {
                            controller.updateSelection(at: position, range: field.selectedRange())
                        }
                    } else {
                        newCells.append(position)
                    }
                    field.position = position
                    field.setAccessibilityLabel(markdownTableAccessibilityLabel(for: position))
                    updatedFields[position] = field
                    columnWidthConstraints[column].append(field.widthConstraint)
                }
            }
            fields = updatedFields
            cellHeights = updatedHeights
            rowHeights.removeAll()
            cellLayout.reindex(
                positions: Array(updatedFields.keys),
                columnCount: previousColumns.count,
                previousPositions: previousPositions,
                previousColumns: previousColumns
            )
            updateColumnWidths(changedCells: newCells, remeasuringAllRows: true)
            invalidateIntrinsicContentSize()
        }

        private func makeRow(section: MarkdownTableCellPosition.Section, columnCount: Int) -> [NSView] {
            (0 ..< columnCount).map { column in
                makeField(at: MarkdownTableCellPosition(section: section, column: column))
            }
        }

        private func makeField(at position: MarkdownTableCellPosition) -> AppKitMarkdownTableCellTextView {
            let field = AppKitMarkdownTableCellTextView(position: position)
            field.onContextSelection = { [weak controller, weak field] range in
                guard let field else {
                    return
                }
                controller?.updateSelection(at: field.position, range: range)
            }
            configureText(of: field)
            field.delegate = self
            field.backgroundColor = position.section == .header ? .controlBackgroundColor : .textBackgroundColor
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
            field.setAccessibilityLabel(markdownTableAccessibilityLabel(for: position))
            field.widthConstraint.isActive = true
            return field
        }

        /// Sets a cell's text the same way for new and updated cells.
        private func configureText(of field: AppKitMarkdownTableCellTextView) {
            field.textStorage?.setAttributedString(controller.richText(at: field.position))
            field.alignment = controller.alignment(at: field.position)
            field.typingAttributes = [.font: NSFont.preferredFont(forTextStyle: .body)]
        }

        /// Lays out changed cells, or every cell when nil. Removing cells can lower
        /// any row's height, so structural changes check every row.
        @discardableResult private func updateColumnWidths(
            changedCells: [MarkdownTableCellPosition]? = nil,
            remeasuringAllRows: Bool = false
        ) -> Bool {
            let fields = self.fields
            let previousWidths = cellLayout.widths
            let affected = cellLayout.update(changedCells: changedCells, availableWidth: maximumWidth) { position in
                guard let field = fields[position] else {
                    return MarkdownTableColumnLayout.minimumColumnWidth
                }
                return ceil(field.attributedString().size().width) + 16
            }
            let widths = cellLayout.widths
            guard gridView.numberOfColumns == widths.count else {
                return false
            }
            for column in widths.indices where !previousWidths.indices.contains(column) || previousWidths[column] != widths[column] {
                gridView.column(at: column).width = widths[column]
                for constraint in columnWidthConstraints[column] where constraint.constant != widths[column] {
                    constraint.constant = widths[column]
                }
            }
            var affectedRows = Set<MarkdownTableCellPosition.Section>()
            if remeasuringAllRows {
                affectedRows.insert(.header)
                affectedRows.formUnion(controller.table.rows.indices.map { .body(row: $0) })
            }
            for position in affected {
                guard let field = fields[position] else {
                    continue
                }
                // Cells inserted into an existing column take its width here.
                if field.widthConstraint.constant != widths[position.column] {
                    field.widthConstraint.constant = widths[position.column]
                }
                field.layoutWidth = widths[position.column]
                let height = field.intrinsicContentSize.height
                if cellHeights[position] != height {
                    cellHeights[position] = height
                    field.invalidateIntrinsicContentSize()
                }
                affectedRows.insert(position.section)
            }
            var heightChanged = false
            for section in affectedRows {
                let height = widths.indices.compactMap { cellHeights[.init(section: section, column: $0)] }.max() ?? 28
                if rowHeights[section] != height {
                    rowHeights[section] = height
                    heightChanged = true
                }
            }
            let dimensionsChanged = previousWidths != widths || heightChanged
            if dimensionsChanged {
                needsLayout = true
            }
            return dimensionsChanged
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
            attachmentResizeCount += 1
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
            focusActiveSelection()
        }

        private func focusActiveSelection() {
            guard let selection = controller.activeSelection,
                  let field = fields[selection.position] else {
                return
            }
            field.setSelectedRange(clamped(selection.range, toUTF16Length: field.string.utf16.count))
            window?.makeFirstResponder(field)
        }
    }

    @MainActor private final class AppKitMarkdownTableCellTextView: NSTextView {
        var position: MarkdownTableCellPosition
        var onContextSelection: ((NSRange) -> Void)?
        var layoutWidth: CGFloat = MarkdownTableColumnLayout.minimumColumnWidth
        private(set) lazy var widthConstraint = widthAnchor.constraint(equalToConstant: MarkdownTableColumnLayout.minimumColumnWidth)
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
