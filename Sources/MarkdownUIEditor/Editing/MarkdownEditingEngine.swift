import Foundation

/// Applies structural editor commands to the typed Markdown document model.
///
/// The engine has no TextKit dependency. The session translates native selections
/// into `MarkdownLogicalSelection` before calling it.
enum MarkdownEditingEngine {
    /// Applies a command and returns the updated document and logical selection.
    static func apply(
        _ command: MarkdownEditorCommand,
        to document: MarkdownDocument,
        selection: MarkdownLogicalSelection
    ) -> MarkdownEditingResult {
        guard selectionIsValid(selection, in: document) else {
            return unchanged(document, selection)
        }

        switch command {
            case let .toggleInline(style):
                return editInlines(document, selection) { inlines, range in
                    toggle(style, in: &inlines, range: range)
                }
            case let .setLink(destination, title):
                return editInlines(document, selection) { inlines, range in
                    wrapLink(destination: destination, title: title, in: &inlines, range: range)
                }
            case .removeLink:
                return editInlines(document, selection) { inlines, range in
                    removeLinks(in: &inlines, range: range)
                }
            case let .insertImage(source, title, alt):
                return insertImage(source: source, title: title, alt: alt, in: document, selection: selection)
            case let .convertBlock(style):
                return convertBlock(style, document, selection)
            case let .convertList(style):
                return convertList(style, document, selection)
            case .toggleTask:
                return toggleTask(document, selection)
            case .indent:
                return indent(document, selection)
            case .outdent:
                return outdent(document, selection)
            case .insertThematicBreak:
                return insertBlock(.thematicBreak, in: document, selection: selection)
            case let .insertTable(columns, bodyRows):
                guard columns > 0, bodyRows >= 0 else {
                    return unchanged(document, selection)
                }
                let emptyRow = MarkdownTableRow(cells: Array(repeating: MarkdownTableCell(content: []), count: columns))
                let table = MarkdownTable(
                    alignments: Array(repeating: .none, count: columns),
                    header: emptyRow,
                    rows: Array(repeating: emptyRow, count: bodyRows)
                )
                return insertBlock(.table(table), in: document, selection: selection)
            case .insertTableRow:
                return editTable(document, selection, operation: .insertRow)
            case .deleteTableRow:
                return editTable(document, selection, operation: .deleteRow)
            case let .moveTableRow(direction):
                return editTable(document, selection, operation: .moveRow(direction))
            case .insertTableColumn:
                return editTable(document, selection, operation: .insertColumn)
            case .deleteTableColumn:
                return editTable(document, selection, operation: .deleteColumn)
            case let .moveTableColumn(direction):
                return editTable(document, selection, operation: .moveColumn(direction))
            case let .setTableColumnAlignment(alignment):
                return editTable(document, selection, operation: .align(alignment))
        }
    }
}

private extension MarkdownEditingEngine {
    typealias UTF16Range = Range<Int>

    enum TableOperation {
        case insertRow
        case deleteRow
        case moveRow(MarkdownMoveDirection)
        case insertColumn
        case deleteColumn
        case moveColumn(MarkdownMoveDirection)
        case align(MarkdownTableAlignment)
    }

    static func unchanged(_ document: MarkdownDocument, _ selection: MarkdownLogicalSelection) -> MarkdownEditingResult {
        MarkdownEditingResult(document: document, selection: selection)
    }

    static func insertImage(
        source: String,
        title: String?,
        alt: String,
        in document: MarkdownDocument,
        selection: MarkdownLogicalSelection
    ) -> MarkdownEditingResult {
        let result = editInlines(document, selection) { inlines, range in
            replace(range: range, in: &inlines, with: [.image(source: source, title: title, children: [.text(alt)])])
        }
        guard result.document != document else {
            return result
        }
        var restored = result.selection
        restored.utf16Offset += 1
        restored.utf16Length = 0
        return MarkdownEditingResult(document: result.document, selection: restored)
    }

    static func selectionIsValid(_ selection: MarkdownLogicalSelection, in document: MarkdownDocument) -> Bool {
        guard selection.utf16Offset >= 0, selection.utf16Length >= 0,
              let text = logicalText(at: selection.path, in: document.blocks) else {
            return false
        }
        return validRange(selection, in: text) != nil
    }

    static func logicalText(at path: MarkdownLogicalPath, in blocks: [MarkdownBlock]) -> String? {
        if case let .tableCell(tablePath, row, column) = path {
            guard let block = block(at: tablePath, in: blocks), case let .table(table) = block else {
                return nil
            }
            if row == 0, table.header.cells.indices.contains(column) {
                return plainText(table.header.cells[column].content)
            }
            guard row > 0, table.rows.indices.contains(row - 1), table.rows[row - 1].cells.indices.contains(column) else {
                return nil
            }
            return plainText(table.rows[row - 1].cells[column].content)
        }
        guard let block = block(at: path, in: blocks) else {
            return nil
        }
        switch block {
            case let .paragraph(content),
                 let .heading(_, content): return plainText(content)
            case let .codeBlock(_, content),
                 let .html(content): return content
            case .thematicBreak,
                 .blockquote,
                 .list,
                 .table: return ""
        }
    }

    static func block(at path: MarkdownLogicalPath, in blocks: [MarkdownBlock]) -> MarkdownBlock? {
        switch path {
            case let .block(index):
                return blocks.indices.contains(index) ? blocks[index] : nil
            case let .blockquote(parent, child):
                guard let parentBlock = block(at: parent, in: blocks), case let .blockquote(children) = parentBlock,
                      children.indices.contains(child) else {
                    return nil
                }
                return children[child]
            case let .listItemBlock(listPath, item, blockIndex):
                guard let listBlock = block(at: listPath, in: blocks), case let .list(list) = listBlock,
                      list.items.indices.contains(item), list.items[item].blocks.indices.contains(blockIndex) else {
                    return nil
                }
                return list.items[item].blocks[blockIndex]
            case .tableCell:
                return nil
        }
    }

    static func editInlines(
        _ document: MarkdownDocument,
        _ selection: MarkdownLogicalSelection,
        edit: (inout [MarkdownInline], UTF16Range) -> Bool
    ) -> MarkdownEditingResult {
        var copy = document
        var changed = false
        let didReachPath = updateInlines(at: selection.path, in: &copy.blocks) { inlines in
            guard let range = validRange(selection, in: plainText(inlines)) else {
                return
            }
            changed = edit(&inlines, range)
        }
        guard didReachPath, changed else {
            return unchanged(document, selection)
        }
        return MarkdownEditingResult(document: copy, selection: selection)
    }

    static func validRange(_ selection: MarkdownLogicalSelection, in text: String) -> UTF16Range? {
        let end = selection.utf16Offset + selection.utf16Length
        guard end >= selection.utf16Offset, end <= text.utf16.count else {
            return nil
        }
        guard stringIndex(atUTF16Offset: selection.utf16Offset, in: text) != nil,
              stringIndex(atUTF16Offset: end, in: text) != nil else {
            return nil
        }
        return selection.utf16Offset ..< end
    }

    static func stringIndex(atUTF16Offset offset: Int, in text: String) -> String.Index? {
        guard offset >= 0, let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: offset, limitedBy: text.utf16.endIndex),
              let index = String.Index(utf16Index, within: text), index == text.endIndex || index == index.encodedOffsetInCharacter(in: text) else {
            return nil
        }
        return index
    }

    static func toggle(_ style: MarkdownInlineStyle, in inlines: inout [MarkdownInline], range: UTF16Range) -> Bool {
        guard !range.isEmpty, let parts = split(inlines, around: range) else {
            return false
        }
        let middle: [MarkdownInline] = if parts.middle.allSatisfy({ carries(style, inline: $0) }) {
            parts.middle.flatMap { removing(style, from: $0) }
        } else {
            switch style {
                case .emphasis: [.emphasis(parts.middle.flatMap { removing(style, from: $0) })]
                case .strong: [.strong(parts.middle.flatMap { removing(style, from: $0) })]
                case .strikethrough: [.strikethrough(parts.middle.flatMap { removing(style, from: $0) })]
                case .code:
                    [.code(plainText(parts.middle))]
            }
        }
        inlines = normalized(parts.before + middle + parts.after)
        return true
    }

    static func carries(_ style: MarkdownInlineStyle, inline: MarkdownInline) -> Bool {
        if unwrapped(inline, as: style) != nil {
            return true
        }
        switch inline {
            case let .emphasis(children),
                 let .strong(children),
                 let .strikethrough(children),
                 let .link(_, _, children):
                return !children.isEmpty && children.allSatisfy { carries(style, inline: $0) }
            case let .text(text): return text.allSatisfy(\.isWhitespace)
            case .softBreak,
                 .lineBreak: return true
            default: return false
        }
    }

    static func removing(_ style: MarkdownInlineStyle, from inline: MarkdownInline) -> [MarkdownInline] {
        if let children = unwrapped(inline, as: style) {
            return children.flatMap { removing(style, from: $0) }
        }
        switch inline {
            case let .emphasis(children): return [.emphasis(children.flatMap { removing(style, from: $0) })]
            case let .strong(children): return [.strong(children.flatMap { removing(style, from: $0) })]
            case let .strikethrough(children): return [.strikethrough(children.flatMap { removing(style, from: $0) })]
            case let .link(destination, title, children):
                return [.link(destination: destination, title: title, children: children.flatMap { removing(style, from: $0) })]
            default: return [inline]
        }
    }

    static func unwrapped(_ inline: MarkdownInline, as style: MarkdownInlineStyle) -> [MarkdownInline]? {
        switch (style, inline) {
            case let (.emphasis, .emphasis(children)),
                 let (.strong, .strong(children)),
                 let (.strikethrough, .strikethrough(children)):
                children
            case let (.code, .code(text)):
                [.text(text)]
            default:
                nil
        }
    }

    static func wrapLink(destination: String, title: String?, in inlines: inout [MarkdownInline], range: UTF16Range) -> Bool {
        guard !range.isEmpty, let parts = split(inlines, around: range) else {
            return false
        }
        inlines = normalized(parts.before + [.link(destination: destination, title: title, children: parts.middle.flatMap(removingLinks))] + parts.after)
        return true
    }

    static func removeLinks(in inlines: inout [MarkdownInline], range: UTF16Range) -> Bool {
        guard !range.isEmpty, let parts = split(inlines, around: range) else {
            return false
        }
        let middle = parts.middle.flatMap(removingLinks)
        guard middle != parts.middle else {
            return false
        }
        inlines = normalized(parts.before + middle + parts.after)
        return true
    }

    static func removingLinks(_ inline: MarkdownInline) -> [MarkdownInline] {
        switch inline {
            case let .link(_, _, children):
                children.flatMap(removingLinks)
            case let .emphasis(children): [.emphasis(children.flatMap(removingLinks))]
            case let .strong(children): [.strong(children.flatMap(removingLinks))]
            case let .strikethrough(children): [.strikethrough(children.flatMap(removingLinks))]
            default: [inline]
        }
    }

}

extension MarkdownEditingEngine {
    /// Canonicalizes native formatting runs before they become Markdown delimiters.
    static func normalized(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        let result = mergeAdjacent(inlines).flatMap { inline -> [MarkdownInline] in
            let children: [MarkdownInline]
            let wrap: ([MarkdownInline]) -> MarkdownInline
            switch inline {
                case let .emphasis(content):
                    children = normalized(content.flatMap { removing(.emphasis, from: $0) })
                    wrap = MarkdownInline.emphasis
                case let .strong(content):
                    children = normalized(content.flatMap { removing(.strong, from: $0) })
                    wrap = MarkdownInline.strong
                case let .strikethrough(content):
                    children = normalized(content.flatMap { removing(.strikethrough, from: $0) })
                    wrap = MarkdownInline.strikethrough
                case let .link(destination, title, content):
                    return [.link(destination: destination, title: title, children: normalized(content.flatMap(removingLinks)))]
                default: return [inline]
            }
            // GFM emphasis delimiters cannot open or close against whitespace.
            let text = plainText(children)
            let leading = text.prefix(while: \.isWhitespace).utf16.count
            let trailing = text.reversed().prefix(while: \.isWhitespace).reduce(0) { $0 + String($1).utf16.count }
            guard leading < text.utf16.count,
                  let parts = split(children, around: leading ..< (text.utf16.count - trailing)) else {
                return children
            }
            return parts.before + [wrap(parts.middle)] + parts.after
        }
        return mergeAdjacent(result)
    }

}

private extension MarkdownEditingEngine {
    static func mergeAdjacent(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for inline in inlines {
            if case .text("") = inline {
                continue
            }
            let merged: MarkdownInline? = switch (result.last, inline) {
                case let (.text(previous)?, .text(text)): .text(previous + text)
                case let (.strong(previous)?, .strong(children)): .strong(normalized(previous + children))
                case let (.emphasis(previous)?, .emphasis(children)): .emphasis(normalized(previous + children))
                case let (.strikethrough(previous)?, .strikethrough(children)): .strikethrough(normalized(previous + children))
                case let (.code(previous)?, .code(text)): .code(previous + text)
                case let (.link(oldDestination, oldTitle, previous)?, .link(destination, title, children))
                where oldDestination == destination && oldTitle == title:
                    .link(destination: destination, title: title, children: normalized(previous + children))
                default: nil
            }
            if let merged {
                result[result.count - 1] = merged
            } else {
                result.append(inline)
            }
        }
        return result
    }

    static func replace(range: UTF16Range, in inlines: inout [MarkdownInline], with replacement: [MarkdownInline]) -> Bool {
        guard let parts = split(inlines, around: range) else {
            return false
        }
        inlines = normalized(parts.before + replacement + parts.after)
        return true
    }

    static func split(_ inlines: [MarkdownInline], around range: UTF16Range) -> (before: [MarkdownInline], middle: [MarkdownInline], after: [MarkdownInline])? {
        guard let first = split(inlines, at: range.lowerBound), let second = split(first.right, at: range.count) else {
            return nil
        }
        return (first.left, second.left, second.right)
    }

    static func split(_ inlines: [MarkdownInline], at offset: Int) -> (left: [MarkdownInline], right: [MarkdownInline])? {
        guard offset >= 0 else {
            return nil
        }
        var consumed = 0
        var left: [MarkdownInline] = []
        for (index, inline) in inlines.enumerated() {
            let length = inlineLength(inline)
            if consumed + length < offset {
                left.append(inline)
                consumed += length
                continue
            }
            if consumed + length == offset {
                left.append(inline)
                return (left, Array(inlines.dropFirst(index + 1)))
            }
            let local = offset - consumed
            guard let pieces = split(inline, at: local) else {
                return nil
            }
            if let first = pieces.left {
                left.append(first)
            }
            var right: [MarkdownInline] = []
            if let second = pieces.right {
                right.append(second)
            }
            right.append(contentsOf: inlines.dropFirst(index + 1))
            return (left, right)
        }
        return offset == consumed ? (left, []) : nil
    }

    static func split(_ inline: MarkdownInline, at offset: Int) -> (left: MarkdownInline?, right: MarkdownInline?)? {
        let length = inlineLength(inline)
        if offset == 0 {
            return (nil, inline)
        }
        if offset == length {
            return (inline, nil)
        }
        switch inline {
            case let .code(text):
                guard let index = stringIndex(atUTF16Offset: offset, in: text) else {
                    return nil
                }
                return (.code(String(text[..<index])), .code(String(text[index...])))
            case let .text(text):
                guard let index = stringIndex(atUTF16Offset: offset, in: text) else {
                    return nil
                }
                return (.text(String(text[..<index])), .text(String(text[index...])))
            case let .emphasis(children):
                guard let parts = split(children, at: offset) else {
                    return nil
                }
                return (parts.left.isEmpty ? nil : .emphasis(parts.left), parts.right.isEmpty ? nil : .emphasis(parts.right))
            case let .strong(children):
                guard let parts = split(children, at: offset) else {
                    return nil
                }
                return (parts.left.isEmpty ? nil : .strong(parts.left), parts.right.isEmpty ? nil : .strong(parts.right))
            case let .strikethrough(children):
                guard let parts = split(children, at: offset) else {
                    return nil
                }
                return (parts.left.isEmpty ? nil : .strikethrough(parts.left), parts.right.isEmpty ? nil : .strikethrough(parts.right))
            case let .link(destination, title, children):
                guard let parts = split(children, at: offset) else {
                    return nil
                }
                return (
                    parts.left.isEmpty ? nil : .link(destination: destination, title: title, children: parts.left),
                    parts.right.isEmpty ? nil : .link(destination: destination, title: title, children: parts.right)
                )
            case .softBreak,
                 .lineBreak,
                 .html,
                 .image:
                return nil
        }
    }

    static func inlineLength(_ inline: MarkdownInline) -> Int {
        plainText([inline]).utf16.count
    }

    static func plainText(_ inlines: [MarkdownInline]) -> String {
        inlines.map { inline in
            switch inline {
                case let .text(text),
                     let .code(text),
                     let .html(text): text
                case .softBreak,
                     .lineBreak: "\n"
                case let .emphasis(children),
                     let .strong(children),
                     let .strikethrough(children): plainText(children)
                case let .link(_, _, children): plainText(children)
                case .image: "\u{FFFC}"
            }
        }.joined()
    }

    static func convertBlock(_ style: MarkdownBlockStyle, _ document: MarkdownDocument, _ selection: MarkdownLogicalSelection) -> MarkdownEditingResult {
        var copy = document
        var changed = false
        let reached = updateBlock(at: selection.path, in: &copy.blocks) { block in
            let converted: MarkdownBlock? = switch style {
                case .paragraph:
                    inlineContent(of: block).map(MarkdownBlock.paragraph)
                case let .heading(level):
                    inlineContent(of: block).map { .heading(level: level, content: $0) }
                case .blockquote:
                    .blockquote([block])
                case let .code(info):
                    .codeBlock(info: info, content: blockText(block))
            }
            if let converted, converted != block {
                block = converted
                changed = true
            }
        }
        guard reached, changed else {
            return unchanged(document, selection)
        }
        var restored = selection
        if case .blockquote = style {
            restored.path = .blockquote(parent: selection.path, child: 0)
        }
        return MarkdownEditingResult(document: copy, selection: restored)
    }

    static func inlineContent(of block: MarkdownBlock) -> [MarkdownInline]? {
        switch block {
            case let .paragraph(content),
                 let .heading(_, content): content
            case let .codeBlock(_, content),
                 let .html(content): [.text(content)]
            default: nil
        }
    }

    static func blockText(_ block: MarkdownBlock) -> String {
        if let content = inlineContent(of: block) {
            return plainText(content)
        }
        return ""
    }

    static func convertList(_ style: MarkdownListStyle, _ document: MarkdownDocument, _ selection: MarkdownLogicalSelection) -> MarkdownEditingResult {
        var copy = document
        var changed = false
        if let listPath = containingListPath(selection.path) {
            let reached = updateBlock(at: listPath, in: &copy.blocks) { block in
                guard case var .list(list) = block else {
                    return
                }
                apply(style, to: &list)
                block = .list(list)
                changed = true
            }
            guard reached, changed else {
                return unchanged(document, selection)
            }
            return MarkdownEditingResult(document: copy, selection: selection)
        }
        let reached = updateBlock(at: selection.path, in: &copy.blocks) { block in
            var list = MarkdownList(kind: .unordered, isTight: true, items: [MarkdownListItem(blocks: [block])])
            apply(style, to: &list)
            block = .list(list)
            changed = true
        }
        guard reached, changed else {
            return unchanged(document, selection)
        }
        let restored = MarkdownLogicalSelection(
            path: .listItemBlock(list: selection.path, item: 0, block: 0),
            utf16Offset: selection.utf16Offset,
            utf16Length: selection.utf16Length
        )
        return MarkdownEditingResult(document: copy, selection: restored)
    }

    static func apply(_ style: MarkdownListStyle, to list: inout MarkdownList) {
        switch style {
            case .unordered:
                list.kind = .unordered
                for index in list.items.indices {
                    list.items[index].taskState = nil
                }
            case let .ordered(start):
                list.kind = .ordered(start: start)
                for index in list.items.indices {
                    list.items[index].taskState = nil
                }
            case .task:
                list.kind = .unordered
                for index in list.items.indices where list.items[index].taskState == nil {
                    list.items[index].taskState = .unchecked
                }
        }
    }

    static func toggleTask(_ document: MarkdownDocument, _ selection: MarkdownLogicalSelection) -> MarkdownEditingResult {
        guard let location = listItemLocation(selection.path) else {
            return unchanged(document, selection)
        }
        var copy = document
        var changed = false
        let reached = updateBlock(at: location.list, in: &copy.blocks) { block in
            guard case var .list(list) = block, list.items.indices.contains(location.item), list.items[location.item].taskState != nil else {
                return
            }
            list.items[location.item].taskState = list.items[location.item].taskState == .checked ? .unchecked : .checked
            block = .list(list)
            changed = true
        }
        return reached && changed ? MarkdownEditingResult(document: copy, selection: selection) : unchanged(document, selection)
    }

    static func indent(_ document: MarkdownDocument, _ selection: MarkdownLogicalSelection) -> MarkdownEditingResult {
        guard let location = listItemLocation(selection.path), location.item > 0 else {
            return unchanged(document, selection)
        }
        var copy = document
        var restored = selection
        var changed = false
        _ = updateBlock(at: location.list, in: &copy.blocks) { block in
            guard case var .list(list) = block, list.items.indices.contains(location.item) else {
                return
            }
            let moved = list.items.remove(at: location.item)
            let parent = location.item - 1
            let nestedIndex: Int
            let nestedItem: Int
            if let last = list.items[parent].blocks.indices.last,
               case var .list(nested) = list.items[parent].blocks[last], nested.kind == list.kind {
                nestedItem = nested.items.count
                nested.items.append(moved)
                list.items[parent].blocks[last] = .list(nested)
                nestedIndex = last
            } else {
                nestedIndex = list.items[parent].blocks.count
                nestedItem = 0
                list.items[parent].blocks.append(.list(MarkdownList(kind: list.kind, isTight: list.isTight, items: [moved])))
            }
            block = .list(list)
            let nestedListPath = MarkdownLogicalPath.listItemBlock(list: location.list, item: parent, block: nestedIndex)
            restored.path = .listItemBlock(list: nestedListPath, item: nestedItem, block: location.block)
            changed = true
        }
        return changed ? MarkdownEditingResult(document: copy, selection: restored) : unchanged(document, selection)
    }

    static func outdent(_ document: MarkdownDocument, _ selection: MarkdownLogicalSelection) -> MarkdownEditingResult {
        guard let inner = listItemLocation(selection.path),
              case let .listItemBlock(outerListPath, parentItem, nestedBlock) = inner.list else {
            return unchanged(document, selection)
        }
        var copy = document
        var movedItem: MarkdownListItem?
        _ = updateBlock(at: inner.list, in: &copy.blocks) { block in
            guard case var .list(list) = block, list.items.indices.contains(inner.item) else {
                return
            }
            movedItem = list.items.remove(at: inner.item)
            block = .list(list)
        }
        guard let movedItem else {
            return unchanged(document, selection)
        }
        var inserted = false
        _ = updateBlock(at: outerListPath, in: &copy.blocks) { block in
            guard case var .list(list) = block, list.items.indices.contains(parentItem) else {
                return
            }
            list.items.insert(movedItem, at: parentItem + 1)
            if list.items[parentItem].blocks.indices.contains(nestedBlock),
               case let .list(nested) = list.items[parentItem].blocks[nestedBlock], nested.items.isEmpty {
                list.items[parentItem].blocks.remove(at: nestedBlock)
            }
            block = .list(list)
            inserted = true
        }
        guard inserted else {
            return unchanged(document, selection)
        }
        var restored = selection
        restored.path = .listItemBlock(list: outerListPath, item: parentItem + 1, block: inner.block)
        return MarkdownEditingResult(document: copy, selection: restored)
    }

    static func insertBlock(_ block: MarkdownBlock, in document: MarkdownDocument, selection: MarkdownLogicalSelection) -> MarkdownEditingResult {
        var copy = document
        guard let insertedPath = insert(block, after: structuralBlockPath(selection.path), in: &copy.blocks) else {
            return unchanged(document, selection)
        }
        let restoredPath: MarkdownLogicalPath = if case .table = block {
            .tableCell(table: insertedPath, row: 0, column: 0)
        } else {
            insertedPath
        }
        return MarkdownEditingResult(document: copy, selection: MarkdownLogicalSelection(path: restoredPath))
    }

    static func structuralBlockPath(_ path: MarkdownLogicalPath) -> MarkdownLogicalPath {
        if case let .tableCell(table, _, _) = path {
            return table
        }
        return path
    }

    static func insert(_ newBlock: MarkdownBlock, after path: MarkdownLogicalPath, in blocks: inout [MarkdownBlock]) -> MarkdownLogicalPath? {
        switch path {
            case let .block(index):
                guard blocks.indices.contains(index) else {
                    return nil
                }
                blocks.insert(newBlock, at: index + 1)
                return .block(index + 1)
            case let .blockquote(parent, child):
                var result: MarkdownLogicalPath?
                _ = updateBlock(at: parent, in: &blocks) { block in
                    guard case var .blockquote(children) = block, children.indices.contains(child) else {
                        return
                    }
                    children.insert(newBlock, at: child + 1)
                    block = .blockquote(children)
                    result = .blockquote(parent: parent, child: child + 1)
                }
                return result
            case let .listItemBlock(listPath, item, blockIndex):
                var result: MarkdownLogicalPath?
                _ = updateBlock(at: listPath, in: &blocks) { block in
                    guard case var .list(list) = block, list.items.indices.contains(item), list.items[item].blocks.indices.contains(blockIndex) else {
                        return
                    }
                    list.items[item].blocks.insert(newBlock, at: blockIndex + 1)
                    block = .list(list)
                    result = .listItemBlock(list: listPath, item: item, block: blockIndex + 1)
                }
                return result
            case .tableCell:
                return nil
        }
    }

    static func editTable(_ document: MarkdownDocument, _ selection: MarkdownLogicalSelection, operation: TableOperation) -> MarkdownEditingResult {
        guard case let .tableCell(tablePath, row, column) = selection.path else {
            return unchanged(document, selection)
        }
        var copy = document
        var restored = selection
        var changed = false
        _ = updateBlock(at: tablePath, in: &copy.blocks) { block in
            guard case var .table(table) = block,
                  row >= 0, row <= table.rows.count,
                  column >= 0, column < table.alignments.count,
                  table.header.cells.count == table.alignments.count,
                  table.rows.allSatisfy({ $0.cells.count == table.alignments.count }) else {
                return
            }
            let columnCount = table.alignments.count
            switch operation {
                case .insertRow:
                    table.rows.insert(MarkdownTableRow(cells: Array(repeating: MarkdownTableCell(content: []), count: columnCount)), at: row)
                    restored.path = .tableCell(table: tablePath, row: row + 1, column: column)
                case .deleteRow:
                    guard row > 0 else {
                        return
                    }
                    table.rows.remove(at: row - 1)
                    restored.path = .tableCell(table: tablePath, row: min(row, table.rows.count), column: column)
                case let .moveRow(direction):
                    guard row > 0 else {
                        return
                    }
                    let source = row - 1
                    let destination = direction == .backward ? source - 1 : source + 1
                    guard table.rows.indices.contains(destination) else {
                        return
                    }
                    table.rows.swapAt(source, destination)
                    restored.path = .tableCell(table: tablePath, row: destination + 1, column: column)
                case .insertColumn:
                    table.alignments.insert(.none, at: column + 1)
                    table.header.cells.insert(MarkdownTableCell(content: []), at: column + 1)
                    for index in table.rows.indices {
                        table.rows[index].cells.insert(MarkdownTableCell(content: []), at: column + 1)
                    }
                    restored.path = .tableCell(table: tablePath, row: row, column: column + 1)
                case .deleteColumn:
                    guard columnCount > 1 else {
                        return
                    }
                    table.alignments.remove(at: column)
                    table.header.cells.remove(at: column)
                    for index in table.rows.indices {
                        table.rows[index].cells.remove(at: column)
                    }
                    restored.path = .tableCell(table: tablePath, row: row, column: min(column, columnCount - 2))
                case let .moveColumn(direction):
                    let destination = direction == .backward ? column - 1 : column + 1
                    guard table.alignments.indices.contains(destination) else {
                        return
                    }
                    table.alignments.swapAt(column, destination)
                    table.header.cells.swapAt(column, destination)
                    for index in table.rows.indices {
                        table.rows[index].cells.swapAt(column, destination)
                    }
                    restored.path = .tableCell(table: tablePath, row: row, column: destination)
                case let .align(alignment):
                    table.alignments[column] = alignment
            }
            block = .table(table)
            changed = true
        }
        return changed ? MarkdownEditingResult(document: copy, selection: restored) : unchanged(document, selection)
    }

    @discardableResult static func updateInlines(at path: MarkdownLogicalPath, in blocks: inout [MarkdownBlock], edit: (inout [MarkdownInline]) -> Void) -> Bool {
        switch path {
            case let .tableCell(tablePath, row, column):
                updateBlock(at: tablePath, in: &blocks) { block in
                    guard case var .table(table) = block else {
                        return
                    }
                    if row == 0, table.header.cells.indices.contains(column) {
                        edit(&table.header.cells[column].content)
                    } else if row > 0, table.rows.indices.contains(row - 1), table.rows[row - 1].cells.indices.contains(column) {
                        edit(&table.rows[row - 1].cells[column].content)
                    }
                    block = .table(table)
                }
            default:
                updateBlock(at: path, in: &blocks) { block in
                    switch block {
                        case var .paragraph(content):
                            edit(&content)
                            block = .paragraph(content)
                        case let .heading(level, oldContent):
                            var content = oldContent
                            edit(&content)
                            block = .heading(level: level, content: content)
                        default:
                            break
                    }
                }
        }
    }

    @discardableResult static func updateBlock(at path: MarkdownLogicalPath, in blocks: inout [MarkdownBlock], edit: (inout MarkdownBlock) -> Void) -> Bool {
        switch path {
            case let .block(index):
                guard blocks.indices.contains(index) else {
                    return false
                }
                edit(&blocks[index])
                return true
            case let .blockquote(parent, child):
                return updateBlock(at: parent, in: &blocks) { block in
                    guard case var .blockquote(children) = block, children.indices.contains(child) else {
                        return
                    }
                    edit(&children[child])
                    block = .blockquote(children)
                }
            case let .listItemBlock(listPath, item, blockIndex):
                return updateBlock(at: listPath, in: &blocks) { block in
                    guard case var .list(list) = block, list.items.indices.contains(item), list.items[item].blocks.indices.contains(blockIndex) else {
                        return
                    }
                    edit(&list.items[item].blocks[blockIndex])
                    block = .list(list)
                }
            case .tableCell:
                return false
        }
    }

    static func containingListPath(_ path: MarkdownLogicalPath) -> MarkdownLogicalPath? {
        switch path {
            case let .listItemBlock(list, _, _): list
            case let .blockquote(parent, _): containingListPath(parent)
            case let .tableCell(table, _, _): containingListPath(table)
            case .block: nil
        }
    }

    static func listItemLocation(_ path: MarkdownLogicalPath) -> (list: MarkdownLogicalPath, item: Int, block: Int)? {
        switch path {
            case let .listItemBlock(list, item, block): (list, item, block)
            case let .blockquote(parent, _): listItemLocation(parent)
            case let .tableCell(table, _, _): listItemLocation(table)
            case .block: nil
        }
    }
}

private extension String.Index {
    func encodedOffsetInCharacter(in text: String) -> String.Index {
        guard self != text.endIndex else {
            return self
        }
        return text.rangeOfComposedCharacterSequence(at: self).lowerBound
    }
}
