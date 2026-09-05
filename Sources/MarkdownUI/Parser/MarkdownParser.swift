internal import cmark_gfm
internal import cmark_gfm_extensions
import Foundation

extension [BlockNode] {
    init(markdown: String) {
        let blocks = UnsafeNode.parseMarkdown(markdown) { document in
            document.children.compactMap(BlockNode.init(unsafeNode:))
        }
        self.init(blocks ?? .init())
    }

    func renderMarkdown() -> String {
        UnsafeNode.makeDocument(self) { document in
            document.prepareOrderedTasksForTextRendering(.markdown)
            guard let buffer = cmark_render_commonmark(document, CMARK_OPT_DEFAULT, 0) else {
                return ""
            }
            defer { cmark_get_default_mem_allocator().pointee.free(buffer) }
            return String(cString: buffer)
        } ?? ""
    }

    func renderPlainText() -> String {
        UnsafeNode.makeDocument(self) { document in
            document.prepareOrderedTasksForTextRendering(.plainText)
            guard let buffer = cmark_render_plaintext(document, CMARK_OPT_DEFAULT, 0) else {
                return ""
            }
            defer { cmark_get_default_mem_allocator().pointee.free(buffer) }
            return String(cString: buffer)
        } ?? ""
    }

    func renderHTML() -> String {
        UnsafeNode.makeDocument(self) { document in
            guard let buffer = cmark_render_html(document, CMARK_OPT_DEFAULT, nil) else {
                return ""
            }
            defer { cmark_get_default_mem_allocator().pointee.free(buffer) }
            return String(cString: buffer)
        } ?? ""
    }
}

private extension BlockNode {
    init?(unsafeNode: UnsafeNode) {
        switch unsafeNode.nodeType {
            case .blockquote:
                self = .blockquote(children: unsafeNode.children.compactMap(BlockNode.init(unsafeNode:)))
            case .list:
                if unsafeNode.listType == CMARK_BULLET_LIST,
                   unsafeNode.children.allSatisfy(\.isTaskListItem) {
                    self = .taskList(
                        isTight: unsafeNode.isTightList,
                        items: unsafeNode.children.map(RawTaskListItem.init(unsafeNode:))
                    )
                } else {
                    switch unsafeNode.listType {
                        case CMARK_BULLET_LIST:
                            self = .bulletedList(
                                isTight: unsafeNode.isTightList,
                                items: unsafeNode.children.map(RawListItem.init(unsafeNode:))
                            )
                        case CMARK_ORDERED_LIST:
                            self = .numberedList(
                                isTight: unsafeNode.isTightList,
                                start: unsafeNode.listStart,
                                items: unsafeNode.children.map(RawListItem.init(unsafeNode:))
                            )
                        default:
                            fatalError("cmark reported a list node without a list type.")
                    }
                }
            case .codeBlock:
                self = .codeBlock(fenceInfo: unsafeNode.fenceInfo, content: unsafeNode.literal ?? "")
            case .htmlBlock:
                self = .htmlBlock(content: unsafeNode.literal ?? "")
            case .paragraph:
                self = .paragraph(content: unsafeNode.children.compactMap(InlineNode.init(unsafeNode:)))
            case .heading:
                self = .heading(
                    level: unsafeNode.headingLevel,
                    content: unsafeNode.children.compactMap(InlineNode.init(unsafeNode:))
                )
            case .table:
                self = .table(
                    columnAlignments: unsafeNode.tableAlignments,
                    rows: unsafeNode.children.map(RawTableRow.init(unsafeNode:))
                )
            case .thematicBreak:
                self = .thematicBreak
            default:
                assertionFailure("Unhandled node type '\(unsafeNode.nodeType)' in BlockNode.")
                return nil
        }
    }
}

private extension RawListItem {
    init(unsafeNode: UnsafeNode) {
        guard unsafeNode.nodeType == .item || unsafeNode.nodeType == .taskListItem else {
            fatalError("Expected a list item but got a '\(unsafeNode.nodeType)' instead.")
        }
        self.init(
            children: unsafeNode.children.compactMap(BlockNode.init(unsafeNode:)),
            isCompleted: unsafeNode.isTaskListItem ? unsafeNode.isTaskListItemChecked : nil
        )
    }
}

private extension RawTaskListItem {
    init(unsafeNode: UnsafeNode) {
        guard unsafeNode.nodeType == .taskListItem || unsafeNode.nodeType == .item else {
            fatalError("Expected a list item but got a '\(unsafeNode.nodeType)' instead.")
        }
        self.init(
            isCompleted: unsafeNode.isTaskListItemChecked,
            children: unsafeNode.children.compactMap(BlockNode.init(unsafeNode:))
        )
    }
}

private extension RawTableRow {
    init(unsafeNode: UnsafeNode) {
        guard unsafeNode.nodeType == .tableRow || unsafeNode.nodeType == .tableHead else {
            fatalError("Expected a table row but got a '\(unsafeNode.nodeType)' instead.")
        }
        self.init(cells: unsafeNode.children.map(RawTableCell.init(unsafeNode:)))
    }
}

private extension RawTableCell {
    init(unsafeNode: UnsafeNode) {
        guard unsafeNode.nodeType == .tableCell else {
            fatalError("Expected a table cell but got a '\(unsafeNode.nodeType)' instead.")
        }
        self.init(content: unsafeNode.children.compactMap(InlineNode.init(unsafeNode:)))
    }
}

private extension InlineNode {
    init?(unsafeNode: UnsafeNode) {
        switch unsafeNode.nodeType {
            case .text:
                self = .text(unsafeNode.literal ?? "")
            case .softBreak:
                self = .softBreak
            case .lineBreak:
                self = .lineBreak
            case .code:
                self = .code(unsafeNode.literal ?? "")
            case .html:
                self = .html(unsafeNode.literal ?? "")
            case .emphasis:
                self = .emphasis(children: unsafeNode.children.compactMap(InlineNode.init(unsafeNode:)))
            case .strong:
                self = .strong(children: unsafeNode.children.compactMap(InlineNode.init(unsafeNode:)))
            case .strikethrough:
                self = .strikethrough(children: unsafeNode.children.compactMap(InlineNode.init(unsafeNode:)))
            case .link:
                self = .link(
                    destination: unsafeNode.url ?? "",
                    children: unsafeNode.children.compactMap(InlineNode.init(unsafeNode:))
                )
            case .image:
                self = .image(
                    source: unsafeNode.url ?? "",
                    children: unsafeNode.children.compactMap(InlineNode.init(unsafeNode:))
                )
            default:
                assertionFailure("Unhandled node type '\(unsafeNode.nodeType)' in InlineNode.")
                return nil
        }
    }
}

private typealias UnsafeNode = UnsafeMutablePointer<cmark_node>

private enum TextRenderingFormat {
    case markdown
    case plainText
}

private extension UnsafeNode {
    func prepareOrderedTasksForTextRendering(_ format: TextRenderingFormat) {
        switch cmark_node_get_type(self) {
            case CMARK_NODE_DOCUMENT,
                 CMARK_NODE_BLOCK_QUOTE,
                 CMARK_NODE_LIST:
                break
            case CMARK_NODE_ITEM:
                // Only task items receive a syntax extension when constructing this tree.
                // cmark renders them as bullets even inside ordered lists, so use an
                // ordinary numbered item with a literal checkbox prefix instead.
                if cmark_node_get_syntax_extension(self) != nil,
                   let parent = cmark_node_parent(self), parent.listType == CMARK_ORDERED_LIST,
                   let paragraph = cmark_node_first_child(self),
                   cmark_node_get_type(paragraph) == CMARK_NODE_PARAGRAPH {
                    let prefix = self.isTaskListItemChecked ? "[x] " : "[ ] "
                    let type = format == .markdown ? CMARK_NODE_CUSTOM_INLINE : CMARK_NODE_TEXT
                    if let marker = cmark_node_new(type) {
                        switch format {
                            case .markdown:
                                cmark_node_set_on_enter(marker, prefix)
                            case .plainText:
                                cmark_node_set_literal(marker, prefix)
                        }
                        cmark_node_prepend_child(paragraph, marker)
                        cmark_node_set_syntax_extension(self, nil)
                    }
                }
            default:
                // Paragraphs, headings and tables cannot contain nested list blocks.
                return
        }
        for child in self.children {
            child.prepareOrderedTasksForTextRendering(format)
        }
    }

    var nodeType: NodeType {
        let typeString = String(cString: cmark_node_get_type_string(self))
        guard let nodeType = NodeType(rawValue: typeString) else {
            fatalError("Unknown node type '\(typeString)' found.")
        }
        return nodeType
    }

    var children: UnsafeNodeSequence {
        .init(cmark_node_first_child(self))
    }

    var literal: String? {
        cmark_node_get_literal(self).map(String.init(cString:))
    }

    var url: String? {
        cmark_node_get_url(self).map(String.init(cString:))
    }

    var isTaskListItem: Bool {
        self.nodeType == .taskListItem
    }

    var listType: cmark_list_type {
        cmark_node_get_list_type(self)
    }

    var listStart: Int {
        Int(cmark_node_get_list_start(self))
    }

    var isTaskListItemChecked: Bool {
        cmark_gfm_extensions_get_tasklist_item_checked(self)
    }

    var isTightList: Bool {
        cmark_node_get_list_tight(self) != 0
    }

    var fenceInfo: String? {
        cmark_node_get_fence_info(self).map(String.init(cString:))
    }

    var headingLevel: Int {
        Int(cmark_node_get_heading_level(self))
    }

    var tableColumns: Int {
        Int(cmark_gfm_extensions_get_table_columns(self))
    }

    var tableAlignments: [RawTableColumnAlignment] {
        (0 ..< self.tableColumns).map { column in
            let ascii = cmark_gfm_extensions_get_table_alignments(self)[column]
            let scalar = UnicodeScalar(ascii)
            let character = Character(scalar)
            return .init(rawValue: character) ?? .none
        }
    }

    static func parseMarkdown<ResultType>(
        _ markdown: String,
        body: (UnsafeNode) throws -> ResultType
    ) rethrows -> ResultType? {
        cmark_gfm_core_extensions_ensure_registered()

        // Create a Markdown parser and attach the GitHub syntax extensions

        let parser = cmark_parser_new(CMARK_OPT_DEFAULT)
        defer { cmark_parser_free(parser) }

        let extensionNames: Set<String> = if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            ["autolink", "strikethrough", "tagfilter", "tasklist", "table"]
        } else {
            ["autolink", "strikethrough", "tagfilter", "tasklist"]
        }

        for extensionName in extensionNames {
            guard let syntaxExtension = cmark_find_syntax_extension(extensionName) else {
                continue
            }
            cmark_parser_attach_syntax_extension(parser, syntaxExtension)
        }

        // Parse the Markdown document

        cmark_parser_feed(parser, markdown, markdown.utf8.count)

        guard let document = cmark_parser_finish(parser) else {
            return nil
        }

        defer { cmark_node_free(document) }
        return try body(document)
    }

    static func makeDocument<ResultType>(
        _ blocks: [BlockNode],
        body: (UnsafeNode) throws -> ResultType
    ) rethrows -> ResultType? {
        cmark_gfm_core_extensions_ensure_registered()
        guard let document = cmark_node_new(CMARK_NODE_DOCUMENT) else {
            return nil
        }
        blocks.lazy.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(document, $0) }

        defer { cmark_node_free(document) }
        return try body(document)
    }

    static func make(_ block: BlockNode) -> UnsafeNode? {
        switch block {
            case let .blockquote(children):
                guard let node = cmark_node_new(CMARK_NODE_BLOCK_QUOTE) else {
                    return nil
                }
                children.lazy.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
                return node
            case let .bulletedList(isTight, items):
                guard let node = cmark_node_new(CMARK_NODE_LIST) else {
                    return nil
                }
                cmark_node_set_list_type(node, CMARK_BULLET_LIST)
                cmark_node_set_list_tight(node, isTight ? 1 : 0)
                items.lazy.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
                return node
            case let .numberedList(isTight, start, items):
                guard let node = cmark_node_new(CMARK_NODE_LIST) else {
                    return nil
                }
                cmark_node_set_list_type(node, CMARK_ORDERED_LIST)
                cmark_node_set_list_tight(node, isTight ? 1 : 0)
                cmark_node_set_list_start(node, Int32(start))
                items.lazy.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
                return node
            case let .taskList(isTight, items):
                guard let node = cmark_node_new(CMARK_NODE_LIST) else {
                    return nil
                }
                cmark_node_set_list_type(node, CMARK_BULLET_LIST)
                cmark_node_set_list_tight(node, isTight ? 1 : 0)
                items.lazy.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
                return node
            case let .codeBlock(fenceInfo, content):
                guard let node = cmark_node_new(CMARK_NODE_CODE_BLOCK) else {
                    return nil
                }
                if let fenceInfo {
                    cmark_node_set_fence_info(node, fenceInfo)
                }
                cmark_node_set_literal(node, content)
                return node
            case let .htmlBlock(content):
                guard let node = cmark_node_new(CMARK_NODE_HTML_BLOCK) else {
                    return nil
                }
                cmark_node_set_literal(node, content)
                return node
            case let .paragraph(content):
                guard let node = cmark_node_new(CMARK_NODE_PARAGRAPH) else {
                    return nil
                }
                content.lazy.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
                return node
            case let .heading(level, content):
                guard let node = cmark_node_new(CMARK_NODE_HEADING) else {
                    return nil
                }
                cmark_node_set_heading_level(node, Int32(level))
                content.lazy.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
                return node
            case let .table(columnAlignments, rows):
                return self.makeTable(columnAlignments: columnAlignments, rows: rows)
            case .thematicBreak:
                guard let node = cmark_node_new(CMARK_NODE_THEMATIC_BREAK) else {
                    return nil
                }
                return node
        }
    }

    static func makeTable(
        columnAlignments: [RawTableColumnAlignment],
        rows: [RawTableRow]
    ) -> UnsafeNode? {
        guard let table = cmark_find_syntax_extension("table"),
              let node = cmark_node_new_with_ext(ExtensionNodeTypes.shared.CMARK_NODE_TABLE, table) else {
            return nil
        }
        cmark_gfm_extensions_set_table_columns(node, UInt16(columnAlignments.count))
        var alignments = columnAlignments.map { $0.rawValue.asciiValue ?? 0 }
        cmark_gfm_extensions_set_table_alignments(node, UInt16(columnAlignments.count), &alignments)
        rows.lazy.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
        if let header = cmark_node_first_child(node) {
            cmark_gfm_extensions_set_table_row_is_header(header, 1)
        }
        return node
    }

    static func make(_ item: RawListItem) -> UnsafeNode? {
        if let isCompleted = item.isCompleted {
            return self.make(RawTaskListItem(isCompleted: isCompleted, children: item.children))
        }
        guard let node = cmark_node_new(CMARK_NODE_ITEM) else {
            return nil
        }
        item.children.lazy.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
        return node
    }

    static func make(_ item: RawTaskListItem) -> UnsafeNode? {
        guard let tasklist = cmark_find_syntax_extension("tasklist"),
              let node = cmark_node_new_with_ext(CMARK_NODE_ITEM, tasklist) else {
            return nil
        }
        cmark_gfm_extensions_set_tasklist_item_checked(node, item.isCompleted)
        item.children.lazy.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
        return node
    }

    static func make(_ tableRow: RawTableRow) -> UnsafeNode? {
        guard let table = cmark_find_syntax_extension("table"),
              let node = cmark_node_new_with_ext(ExtensionNodeTypes.shared.CMARK_NODE_TABLE_ROW, table) else {
            return nil
        }
        tableRow.cells.lazy.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
        return node
    }

    static func make(_ tableCell: RawTableCell) -> UnsafeNode? {
        guard let table = cmark_find_syntax_extension("table"),
              let node = cmark_node_new_with_ext(ExtensionNodeTypes.shared.CMARK_NODE_TABLE_CELL, table) else {
            return nil
        }
        tableCell.content.lazy.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
        return node
    }

    static func make(_ inline: InlineNode) -> UnsafeNode? {
        switch inline {
            case let .text(content):
                guard let node = cmark_node_new(CMARK_NODE_TEXT) else {
                    return nil
                }
                cmark_node_set_literal(node, content)
                return node
            case .softBreak:
                return cmark_node_new(CMARK_NODE_SOFTBREAK)
            case .lineBreak:
                return cmark_node_new(CMARK_NODE_LINEBREAK)
            case let .code(content):
                guard let node = cmark_node_new(CMARK_NODE_CODE) else {
                    return nil
                }
                cmark_node_set_literal(node, content)
                return node
            case let .html(content):
                guard let node = cmark_node_new(CMARK_NODE_HTML_INLINE) else {
                    return nil
                }
                cmark_node_set_literal(node, content)
                return node
            case let .emphasis(children):
                guard let node = cmark_node_new(CMARK_NODE_EMPH) else {
                    return nil
                }
                children.lazy.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
                return node
            case let .strong(children):
                guard let node = cmark_node_new(CMARK_NODE_STRONG) else {
                    return nil
                }
                children.lazy.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
                return node
            case let .strikethrough(children):
                guard let strikethrough = cmark_find_syntax_extension("strikethrough"),
                      let node = cmark_node_new_with_ext(
                          ExtensionNodeTypes.shared.CMARK_NODE_STRIKETHROUGH, strikethrough
                      ) else {
                    return nil
                }
                children.lazy.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
                return node
            case let .link(destination, children):
                guard let node = cmark_node_new(CMARK_NODE_LINK) else {
                    return nil
                }
                cmark_node_set_url(node, destination)
                children.lazy.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
                return node
            case let .image(source, children):
                guard let node = cmark_node_new(CMARK_NODE_IMAGE) else {
                    return nil
                }
                cmark_node_set_url(node, source)
                children.lazy.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
                return node
        }
    }
}

private enum NodeType: String {
    case document
    case blockquote = "block_quote"
    case list
    case item
    case codeBlock = "code_block"
    case htmlBlock = "html_block"
    case customBlock = "custom_block"
    case paragraph
    case heading
    case thematicBreak = "thematic_break"
    case text
    case softBreak = "softbreak"
    case lineBreak = "linebreak"
    case code
    case html = "html_inline"
    case customInline = "custom_inline"
    case emphasis = "emph"
    case strong
    case link
    case image
    case inlineAttributes = "attribute"
    case none = "NONE"
    case unknown = "<unknown>"

    // Extensions

    case strikethrough
    case table
    case tableHead = "table_header"
    case tableRow = "table_row"
    case tableCell = "table_cell"
    case taskListItem = "tasklist"
}

private struct UnsafeNodeSequence: Sequence {
    struct Iterator: IteratorProtocol {
        private var node: UnsafeNode?

        init(_ node: UnsafeNode?) {
            self.node = node
        }

        mutating func next() -> UnsafeNode? {
            guard let node else {
                return nil
            }
            defer { self.node = cmark_node_next(node) }
            return node
        }
    }

    private let node: UnsafeNode?

    init(_ node: UnsafeNode?) {
        self.node = node
    }

    func makeIterator() -> Iterator {
        .init(self.node)
    }
}

/// Extension node types are not exported in `cmark_gfm_extensions`,
/// so we need to look for them in the symbol table
private struct ExtensionNodeTypes {
    let CMARK_NODE_TABLE: cmark_node_type
    let CMARK_NODE_TABLE_ROW: cmark_node_type
    let CMARK_NODE_TABLE_CELL: cmark_node_type
    let CMARK_NODE_STRIKETHROUGH: cmark_node_type

    static let shared = ExtensionNodeTypes()

    private init() {
        func findNodeType(_ name: String, in handle: UnsafeMutableRawPointer!) -> cmark_node_type? {
            guard let symbol = dlsym(handle, name) else {
                return nil
            }
            return symbol.assumingMemoryBound(to: cmark_node_type.self).pointee
        }

        let handle = dlopen(nil, RTLD_LAZY)

        self.CMARK_NODE_TABLE = findNodeType("CMARK_NODE_TABLE", in: handle) ?? CMARK_NODE_NONE
        self.CMARK_NODE_TABLE_ROW = findNodeType("CMARK_NODE_TABLE_ROW", in: handle) ?? CMARK_NODE_NONE
        self.CMARK_NODE_TABLE_CELL =
            findNodeType("CMARK_NODE_TABLE_CELL", in: handle) ?? CMARK_NODE_NONE
        self.CMARK_NODE_STRIKETHROUGH =
            findNodeType("CMARK_NODE_STRIKETHROUGH", in: handle) ?? CMARK_NODE_NONE

        dlclose(handle)
    }
}
