internal import cmark_gfm
internal import cmark_gfm_extensions
import Foundation

public extension MarkdownDocument {
    /// Parses GitHub Flavored Markdown into the editor's structured document model.
    ///
    /// Unsupported nodes are omitted rather than represented as invalid model values.
    init(markdown: String) {
        self = CMarkDocument.parse(markdown) ?? MarkdownDocument()
    }

    /// Serializes the document as normalized GitHub Flavored Markdown.
    var markdown: String {
        CMarkDocument.render(self) ?? ""
    }
}

private typealias CMarkNode = UnsafeMutablePointer<cmark_node>

/// Thin ownership wrapper around cmark-gfm parsing and rendering calls.
private enum CMarkDocument {
    /// Parses source with the editor's enabled GFM extensions.
    static func parse(_ markdown: String) -> MarkdownDocument? {
        registerExtensions()

        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else {
            return nil
        }
        defer { cmark_parser_free(parser) }

        for name in extensionNames {
            if let syntaxExtension = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, syntaxExtension)
            }
        }

        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let root = cmark_parser_finish(parser) else {
            return nil
        }
        defer { cmark_node_free(root) }

        return MarkdownDocument(blocks: root.children.markdownBlocks)
    }

    /// Renders the model through cmark-gfm's CommonMark/GFM renderer.
    static func render(_ document: MarkdownDocument) -> String? {
        registerExtensions()

        guard let root = cmark_node_new(CMARK_NODE_DOCUMENT) else {
            return nil
        }
        defer { cmark_node_free(root) }

        for block in document.blocks {
            guard let child = CMarkNode.make(block) else {
                continue
            }
            cmark_node_append_child(root, child)
        }

        root.protectEmphasisBoundaries()
        guard let buffer = cmark_render_commonmark(root, CMARK_OPT_DEFAULT, 0) else {
            return nil
        }
        defer {
            let allocator = cmark_get_default_mem_allocator()
            allocator?.pointee.free(buffer)
        }
        return String(cString: buffer)
    }

    private static let extensionNames = ["autolink", "strikethrough", "tagfilter", "tasklist", "table"]

    private static func registerExtensions() {
        cmark_gfm_core_extensions_ensure_registered()
    }
}

private extension MarkdownBlock {
    init?(cmarkNode node: CMarkNode) {
        switch node.type {
            case .blockquote:
                self = .blockquote(node.children.markdownBlocks)
            case .list:
                let kind: MarkdownListKind
                switch cmark_node_get_list_type(node) {
                    case CMARK_BULLET_LIST:
                        kind = .unordered
                    case CMARK_ORDERED_LIST:
                        kind = .ordered(start: Int(cmark_node_get_list_start(node)))
                    default:
                        return nil
                }
                let items = node.children.compactMap(MarkdownListItem.init(cmarkNode:))
                self = .list(.init(kind: kind, isTight: cmark_node_get_list_tight(node) != 0, items: items))
            case .codeBlock:
                self = .codeBlock(info: node.optionalFenceInfo, content: node.literal ?? "")
            case .htmlBlock:
                self = .html(node.literal ?? "")
            case .paragraph:
                self = .paragraph(node.children.compactMap(MarkdownInline.init(cmarkNode:)))
            case .heading:
                guard let level = MarkdownHeadingLevel(rawValue: Int(cmark_node_get_heading_level(node))) else {
                    return nil
                }
                self = .heading(level: level, content: node.children.compactMap(MarkdownInline.init(cmarkNode:)))
            case .table:
                let tableRows = Array(node.children)
                guard let headerNode = tableRows.first else {
                    return nil
                }
                let header = MarkdownTableRow(cmarkNode: headerNode)
                let rows = tableRows.dropFirst().map(MarkdownTableRow.init(cmarkNode:))
                self = .table(.init(alignments: node.tableAlignments, header: header, rows: rows))
            case .thematicBreak:
                self = .thematicBreak
            default:
                return nil
        }
    }
}

private extension MarkdownListItem {
    init?(cmarkNode node: CMarkNode) {
        guard node.type == .item || node.type == .taskListItem else {
            return nil
        }
        let taskState: MarkdownTaskState? = switch node.type {
            case .taskListItem:
                cmark_gfm_extensions_get_tasklist_item_checked(node) ? .checked : .unchecked
            default:
                nil
        }
        let blocks = node.children.markdownBlocks
        self.init(
            taskState: taskState,
            blocks: blocks.isEmpty ? [.paragraph([])] : blocks
        )
    }
}

private extension MarkdownTableRow {
    init(cmarkNode node: CMarkNode) {
        self.init(cells: node.children.map(MarkdownTableCell.init(cmarkNode:)))
    }
}

private extension MarkdownTableCell {
    init(cmarkNode node: CMarkNode) {
        self.init(content: node.children.compactMap(MarkdownInline.init(cmarkNode:)))
    }
}

private extension MarkdownInline {
    init?(cmarkNode node: CMarkNode) {
        switch node.type {
            case .text:
                self = .text(node.literal ?? "")
            case .softBreak:
                self = .softBreak
            case .lineBreak:
                self = .lineBreak
            case .code:
                self = .code(node.literal ?? "")
            case .htmlInline:
                self = .html(node.literal ?? "")
            case .emphasis:
                self = .emphasis(node.children.compactMap(MarkdownInline.init(cmarkNode:)))
            case .strong:
                self = .strong(node.children.compactMap(MarkdownInline.init(cmarkNode:)))
            case .strikethrough:
                self = .strikethrough(node.children.compactMap(MarkdownInline.init(cmarkNode:)))
            case .link:
                self = .link(
                    destination: node.url ?? "",
                    title: node.optionalTitle,
                    children: node.children.compactMap(MarkdownInline.init(cmarkNode:))
                )
            case .image:
                self = .image(
                    source: node.url ?? "",
                    title: node.optionalTitle,
                    children: node.children.compactMap(MarkdownInline.init(cmarkNode:))
                )
            default:
                return nil
        }
    }
}

private extension CMarkNode {
    /// cmark's renderer emits delimiters even when punctuation prevents them
    /// from opening or closing. An entity in the adjacent text gives the source
    /// a punctuation boundary without changing the decoded text or formatting.
    func protectEmphasisBoundaries() {
        for child in Array(children) {
            child.protectEmphasisBoundaries()
            guard [.emphasis, .strong, .strikethrough].contains(child.type) else {
                continue
            }
            if let first = cmark_node_first_child(child), first.hasPunctuationBoundary(atStart: true),
               let previous = cmark_node_previous(child), previous.type == .text {
                previous.encodeBoundaryScalar(atStart: false)
            }
            if let last = cmark_node_last_child(child), last.hasPunctuationBoundary(atStart: false),
               let next = cmark_node_next(child), next.type == .text {
                next.encodeBoundaryScalar(atStart: true)
            }
        }
    }

    func hasPunctuationBoundary(atStart: Bool) -> Bool {
        if type == .text, let literal,
           let scalar = atStart ? literal.unicodeScalars.first : literal.unicodeScalars.last {
            return cmark_utf8proc_is_punctuation(Int32(scalar.value)) != 0
        }
        // Code, links, HTML, and nested formatting begin and end with markup.
        return ![.softBreak, .lineBreak].contains(type)
    }

    func encodeBoundaryScalar(atStart: Bool) {
        guard let literal,
              let scalar = atStart ? literal.unicodeScalars.first : literal.unicodeScalars.last else {
            return
        }
        var scalars = literal.unicodeScalars
        guard cmark_utf8proc_is_space(Int32(scalar.value)) == 0,
              cmark_utf8proc_is_punctuation(Int32(scalar.value)) == 0,
              let entity = Self.literalNode(CMARK_NODE_HTML_INLINE, content: "&#\(scalar.value);") else {
            return
        }
        if atStart {
            scalars.removeFirst()
            cmark_node_insert_before(self, entity)
        } else {
            scalars.removeLast()
            cmark_node_insert_after(self, entity)
        }
        cmark_node_set_literal(self, String(scalars))
    }

    var type: CMarkNodeType {
        CMarkNodeType(rawValue: String(cString: cmark_node_get_type_string(self))) ?? .unknown
    }

    var children: CMarkNodeSequence {
        CMarkNodeSequence(cmark_node_first_child(self))
    }

    var literal: String? {
        cmark_node_get_literal(self).map(String.init(cString:))
    }

    var url: String? {
        cmark_node_get_url(self).map(String.init(cString:))
    }

    var optionalTitle: String? {
        cmark_node_get_title(self).map(String.init(cString:)).flatMap { $0.isEmpty ? nil : $0 }
    }

    var optionalFenceInfo: String? {
        cmark_node_get_fence_info(self).map(String.init(cString:)).flatMap { $0.isEmpty ? nil : $0 }
    }

    var tableAlignments: [MarkdownTableAlignment] {
        let count = Int(cmark_gfm_extensions_get_table_columns(self))
        guard count > 0, let values = cmark_gfm_extensions_get_table_alignments(self) else {
            return []
        }
        return (0 ..< count).map { index in
            MarkdownTableAlignment(rawValue: Character(UnicodeScalar(values[index]))) ?? .none
        }
    }

    static func make(_ block: MarkdownBlock) -> CMarkNode? {
        switch block {
            case let .blockquote(blocks):
                guard let node = cmark_node_new(CMARK_NODE_BLOCK_QUOTE) else {
                    return nil
                }
                append(blocks.compactMap(make), to: node)
                return node
            case let .list(list):
                guard let node = cmark_node_new(CMARK_NODE_LIST) else {
                    return nil
                }
                switch list.kind {
                    case .unordered:
                        cmark_node_set_list_type(node, CMARK_BULLET_LIST)
                    case let .ordered(start):
                        cmark_node_set_list_type(node, CMARK_ORDERED_LIST)
                        cmark_node_set_list_start(node, Int32(clamping: start))
                }
                cmark_node_set_list_tight(node, list.isTight ? 1 : 0)
                append(list.items.compactMap(make), to: node)
                return node
            case let .codeBlock(info, content):
                guard let node = cmark_node_new(CMARK_NODE_CODE_BLOCK) else {
                    return nil
                }
                if let info {
                    cmark_node_set_fence_info(node, info)
                }
                cmark_node_set_literal(node, content)
                return node
            case let .html(content):
                guard let node = cmark_node_new(CMARK_NODE_HTML_BLOCK) else {
                    return nil
                }
                cmark_node_set_literal(node, content)
                return node
            case let .paragraph(content):
                guard let node = cmark_node_new(CMARK_NODE_PARAGRAPH) else {
                    return nil
                }
                append(MarkdownEditingEngine.normalized(content).compactMap(make), to: node)
                return node
            case let .heading(level, content):
                guard let node = cmark_node_new(CMARK_NODE_HEADING) else {
                    return nil
                }
                cmark_node_set_heading_level(node, Int32(level.rawValue))
                append(MarkdownEditingEngine.normalized(content).compactMap(make), to: node)
                return node
            case let .table(table):
                return make(table)
            case .thematicBreak:
                return cmark_node_new(CMARK_NODE_THEMATIC_BREAK)
        }
    }

    static func make(_ item: MarkdownListItem) -> CMarkNode? {
        guard let node = cmark_node_new(CMARK_NODE_ITEM) else {
            return nil
        }
        let blocks = item.blocks.compactMap(make)
        append(blocks, to: node)

        // The task-list extension's CommonMark renderer indents an ordinary item
        // that follows a task item as a child of that task. Building an ordinary
        // item with the GFM marker in its first paragraph avoids that lossy output.
        if let taskState = item.taskState {
            let marker = taskState == .checked ? "[x] " : "[ ] "
            if let firstBlock = blocks.first, firstBlock.type == .paragraph,
               let markerNode = literalNode(CMARK_NODE_HTML_INLINE, content: marker) {
                cmark_node_prepend_child(firstBlock, markerNode)
            } else if let paragraph = cmark_node_new(CMARK_NODE_PARAGRAPH),
                      let markerNode = literalNode(CMARK_NODE_HTML_INLINE, content: marker) {
                cmark_node_append_child(paragraph, markerNode)
                cmark_node_prepend_child(node, paragraph)
            }
        }
        return node
    }

    static func make(_ table: MarkdownTable) -> CMarkNode? {
        guard let tableExtension = cmark_find_syntax_extension("table"),
              let node = cmark_node_new_with_ext(CMarkExtensionNodeTypes.shared.table, tableExtension) else {
            return nil
        }
        let columnCount = table.alignments.count
        cmark_gfm_extensions_set_table_columns(node, UInt16(clamping: columnCount))
        var alignments = table.alignments.map { $0.rawValue.asciiValue ?? 0 }
        cmark_gfm_extensions_set_table_alignments(node, UInt16(clamping: columnCount), &alignments)

        guard let header = make(table.header, tableExtension: tableExtension) else {
            cmark_node_free(node)
            return nil
        }
        cmark_gfm_extensions_set_table_row_is_header(header, 1)
        cmark_node_append_child(node, header)
        append(table.rows.compactMap { make($0, tableExtension: tableExtension) }, to: node)
        return node
    }

    static func make(_ row: MarkdownTableRow, tableExtension: UnsafeMutablePointer<cmark_syntax_extension>) -> CMarkNode? {
        guard let node = cmark_node_new_with_ext(CMarkExtensionNodeTypes.shared.tableRow, tableExtension) else {
            return nil
        }
        append(row.cells.compactMap { make($0, tableExtension: tableExtension) }, to: node)
        return node
    }

    static func make(_ cell: MarkdownTableCell, tableExtension: UnsafeMutablePointer<cmark_syntax_extension>) -> CMarkNode? {
        guard let node = cmark_node_new_with_ext(CMarkExtensionNodeTypes.shared.tableCell, tableExtension) else {
            return nil
        }
        append(MarkdownEditingEngine.normalized(cell.content).compactMap(make), to: node)
        return node
    }

    static func make(_ inline: MarkdownInline) -> CMarkNode? {
        switch inline {
            case let .text(content):
                return literalNode(CMARK_NODE_TEXT, content: content)
            case .softBreak:
                return cmark_node_new(CMARK_NODE_SOFTBREAK)
            case .lineBreak:
                return cmark_node_new(CMARK_NODE_LINEBREAK)
            case let .code(content):
                return literalNode(CMARK_NODE_CODE, content: content)
            case let .html(content):
                return literalNode(CMARK_NODE_HTML_INLINE, content: content)
            case let .emphasis(children):
                return containerNode(CMARK_NODE_EMPH, children: children)
            case let .strong(children):
                return containerNode(CMARK_NODE_STRONG, children: children)
            case let .strikethrough(children):
                guard let syntaxExtension = cmark_find_syntax_extension("strikethrough"),
                      let node = cmark_node_new_with_ext(CMarkExtensionNodeTypes.shared.strikethrough, syntaxExtension) else {
                    return nil
                }
                append(children.compactMap(make), to: node)
                return node
            case let .link(destination, title, children):
                guard let node = containerNode(CMARK_NODE_LINK, children: children) else {
                    return nil
                }
                cmark_node_set_url(node, destination)
                if let title {
                    cmark_node_set_title(node, title)
                }
                return node
            case let .image(source, title, children):
                guard let node = containerNode(CMARK_NODE_IMAGE, children: children) else {
                    return nil
                }
                cmark_node_set_url(node, source)
                if let title {
                    cmark_node_set_title(node, title)
                }
                return node
        }
    }

    private static func literalNode(_ type: cmark_node_type, content: String) -> CMarkNode? {
        guard let node = cmark_node_new(type) else {
            return nil
        }
        cmark_node_set_literal(node, content)
        return node
    }

    private static func containerNode(_ type: cmark_node_type, children: [MarkdownInline]) -> CMarkNode? {
        guard let node = cmark_node_new(type) else {
            return nil
        }
        append(children.compactMap(make), to: node)
        return node
    }

    private static func append(_ children: [CMarkNode], to parent: CMarkNode) {
        for child in children {
            cmark_node_append_child(parent, child)
        }
    }
}

private enum CMarkNodeType: String {
    case blockquote = "block_quote"
    case list
    case item
    case codeBlock = "code_block"
    case htmlBlock = "html_block"
    case paragraph
    case heading
    case thematicBreak = "thematic_break"
    case text
    case softBreak = "softbreak"
    case lineBreak = "linebreak"
    case code
    case htmlInline = "html_inline"
    case emphasis = "emph"
    case strong
    case link
    case image
    case strikethrough
    case table
    case tableRow = "table_row"
    case tableCell = "table_cell"
    case taskListItem = "tasklist"
    case unknown
}

/// A sequence that walks cmark's sibling-linked child nodes without taking ownership.
private struct CMarkNodeSequence: Sequence {
    /// Iterator that advances through cmark siblings.
    struct Iterator: IteratorProtocol {
        private var current: CMarkNode?

        init(_ current: CMarkNode?) {
            self.current = current
        }

        mutating func next() -> CMarkNode? {
            guard let current else {
                return nil
            }
            self.current = cmark_node_next(current)
            return current
        }
    }

    private let first: CMarkNode?

    init(_ first: CMarkNode?) {
        self.first = first
    }

    func makeIterator() -> Iterator {
        Iterator(first)
    }
}

private extension CMarkNodeSequence {
    var markdownBlocks: [MarkdownBlock] {
        let nodes = Array(self)
        return nodes.enumerated().compactMap { index, node in
            if node.isCommonMarkListSeparator,
               index > 0,
               index + 1 < nodes.count,
               nodes[index - 1].type == .list,
               nodes[index + 1].type == .list || nodes[index + 1].type == .codeBlock {
                return nil
            }
            return MarkdownBlock(cmarkNode: node)
        }
    }
}

private extension CMarkNode {
    var isCommonMarkListSeparator: Bool {
        type == .htmlBlock && literal == "<!-- end list -->\n"
    }
}

private struct CMarkExtensionNodeTypes: @unchecked Sendable {
    let table: cmark_node_type
    let tableRow: cmark_node_type
    let tableCell: cmark_node_type
    let strikethrough: cmark_node_type

    static let shared = CMarkExtensionNodeTypes()

    private init() {
        let handle = dlopen(nil, RTLD_LAZY)
        defer { dlclose(handle) }

        table = Self.find("CMARK_NODE_TABLE", handle: handle)
        tableRow = Self.find("CMARK_NODE_TABLE_ROW", handle: handle)
        tableCell = Self.find("CMARK_NODE_TABLE_CELL", handle: handle)
        strikethrough = Self.find("CMARK_NODE_STRIKETHROUGH", handle: handle)
    }

    private static func find(_ name: String, handle: UnsafeMutableRawPointer?) -> cmark_node_type {
        guard let symbol = dlsym(handle, name) else {
            return CMARK_NODE_NONE
        }
        return symbol.assumingMemoryBound(to: cmark_node_type.self).pointee
    }
}
