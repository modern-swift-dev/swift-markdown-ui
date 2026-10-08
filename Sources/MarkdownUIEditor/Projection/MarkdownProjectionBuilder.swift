import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

extension NSAttributedString.Key {
    static let markdownEditorNodeID = NSAttributedString.Key("MarkdownUIEditor.NodeID")
    static let markdownEditorObjectKind = NSAttributedString.Key("MarkdownUIEditor.ObjectKind")
    static let markdownEditorTaskChecked = NSAttributedString.Key("MarkdownUIEditor.TaskChecked")
}

/// The native attributed text, source snapshot, and offset index for a document.
///
/// `attributedString` normally aliases the text view's storage after attachment.
/// Canonical source is serialized only when requested, keeping native rendering and
/// table edits from building an unused cmark tree and Markdown string.
struct DocumentProjection {
    /// Attributed text shown by the native editor.
    var attributedString: NSAttributedString
    /// A value snapshot sharing the document's unchanged blocks and inline storage.
    private var sourceDocument: MarkdownDocument
    /// Mapping between visible TextKit positions and Markdown source positions.
    var index: ProjectionIndex
    /// Native typing defers source mapping reconstruction until it is needed.
    private var hasUnreconciledSource = false
    /// Top-level blocks whose native text was typed in place instead of rendered.
    private var nativelyEditedBlocks: Set<Int> = []

    var string: String {
        attributedString.string
    }

    var source: String {
        sourceDocument.markdown
    }

    var sourceUTF16Length: Int {
        index.sourceUTF16Length
    }

    init(
        attributedString: NSAttributedString,
        sourceDocument: MarkdownDocument,
        index: ProjectionIndex
    ) {
        self.attributedString = attributedString
        self.sourceDocument = sourceDocument
        self.index = index
    }

    /// Keeps native storage and unrelated unit identities when a table changes.
    @MainActor mutating func reconcileTable(at path: EditorNodePath, document: MarkdownDocument) -> Bool {
        if hasUnreconciledSource {
            let rebuilt = MarkdownProjectionBuilder().build(document: document, output: .sourceIndex)
            index.refreshSourceMappings(from: rebuilt.index)
            sourceDocument = document
            hasUnreconciledSource = false
            return true
        }
        guard let sourceLength = MarkdownProjectionBuilder.tableSourceLength(at: path, in: document),
              index.replaceTableUnit(at: path, sourceLength: sourceLength) else {
            return false
        }
        sourceDocument = document
        return true
    }

    /// Records a native rich-text edit without rebuilding unrelated units.
    mutating func reconcileRichLeaf(
        at path: EditorNodePath,
        textStorage: NSTextStorage,
        projectionLength: Int,
        kind: ProjectionUnit.Kind? = nil
    ) -> Bool {
        guard let unit = index.unit(at: path),
              index.replaceUnit(
                  at: path,
                  kind: kind,
                  projectionLength: projectionLength,
                  sourceLength: unit.sourceRange.length
              ) else {
            return false
        }
        attributedString = textStorage
        hasUnreconciledSource = true
        if let block = path.rootBlockIndex {
            nativelyEditedBlocks.insert(block)
        }
        return true
    }

    /// Top-level blocks whose native text differs from a fresh projection of `document`.
    ///
    /// Blocks equal at both ends of the document render identically, apart from
    /// paths that move with insertions and removals. Natively typed blocks are
    /// always rendered again, because typed text keeps the attributes TextKit
    /// gave it, so they never end the common prefix or suffix. `forcing` names
    /// an extra such block, for example one whose native edit was rejected.
    func changedBlocks(in document: MarkdownDocument, forcing forcedBlock: Int? = nil) -> [ChangedBlocks] {
        let old = sourceDocument.blocks
        let new = document.blocks
        var dirty = nativelyEditedBlocks
        if let forcedBlock {
            dirty.insert(forcedBlock)
        }
        let commonLength = min(old.count, new.count)
        var prefix = 0
        while prefix < commonLength, dirty.contains(prefix) || old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < commonLength - prefix,
              dirty.contains(old.count - 1 - suffix) || old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        let changed = ChangedBlocks(old: prefix ..< old.count - suffix, new: prefix ..< new.count - suffix)
        var result = changed.old.isEmpty && changed.new.isEmpty ? [] : [changed]
        let delta = new.count - old.count
        for block in dirty where old.indices.contains(block) && !changed.old.contains(block) {
            let target = block < prefix ? block : block + delta
            result.append(ChangedBlocks(old: block ..< block + 1, new: target ..< target + 1))
        }
        // An insertion before a block must move it before that block is rendered again.
        return result.sorted { ($0.old.lowerBound, $0.old.count) < ($1.old.lowerBound, $1.old.count) }
    }

    /// Records native text that now matches a fresh projection of `document`.
    mutating func didRenderChangedBlocks(of document: MarkdownDocument, in textStorage: NSTextStorage) {
        attributedString = textStorage
        sourceDocument = document
        hasUnreconciledSource = false
        nativelyEditedBlocks = []
    }
}

/// Top-level blocks to render again, at their indices before and after a change.
struct ChangedBlocks: Equatable {
    var old: Range<Int>
    var new: Range<Int>
}

/// Builds TextKit-ready attributed text and offset mappings from a document.
@MainActor struct MarkdownProjectionBuilder {
    enum Output {
        case nativeText
        case sourceIndex
    }

    /// Computes the changed table's source length by visiting only its ancestors.
    static func tableSourceLength(at path: EditorNodePath, in document: MarkdownDocument) -> Int? {
        guard case let .block(rootIndex)? = path.components.first,
              document.blocks.indices.contains(rootIndex) else {
            return nil
        }
        var block = document.blocks[rootIndex]
        var components = path.components.dropFirst()
        var prefix = ""
        while let component = components.first {
            components = components.dropFirst()
            switch (block, component) {
                case let (.blockquote(children), .blockquoteBlock(index)):
                    guard children.indices.contains(index) else {
                        return nil
                    }
                    block = children[index]
                    prefix += "> "
                case let (.list(list), .listItem(itemIndex)):
                    guard list.items.indices.contains(itemIndex),
                          case let .itemBlock(blockIndex)? = components.first,
                          list.items[itemIndex].blocks.indices.contains(blockIndex) else {
                        return nil
                    }
                    components = components.dropFirst()
                    let item = list.items[itemIndex]
                    let marker = switch list.kind {
                        case .unordered: "- "
                        case let .ordered(start): "\(start + itemIndex). "
                    }
                    let taskMarker = switch item.taskState {
                        case .checked?: "[x] "
                        case .unchecked?: "[ ] "
                        case nil: ""
                    }
                    prefix += blockIndex == 0
                        ? marker + taskMarker
                        : String(repeating: " ", count: marker.utf16.count + taskMarker.utf16.count)
                    block = item.blocks[blockIndex]
                default:
                    return nil
            }
        }
        guard case let .table(table) = block else {
            return nil
        }
        return BuildState.tableMarkdown(table, prefix: prefix).utf16.count + 1
    }

    /// Callbacks that native attachments use to report edits to their document owner.
    struct Callbacks {
        var onTableChange: ((EditorNodePath, MarkdownTable) -> Void)?
        var tableSelection: ((EditorNodePath) -> MarkdownTableCellSelection?)?
        var onTableSelectionChange: ((EditorNodePath, MarkdownTableCellSelection?) -> Void)?
        var onImageChange: ((EditorNodePath, MarkdownImageMetadata) -> Void)?
    }

    /// Table attachments in text being replaced, which tables render with again.
    ///
    /// Keeping the attachment keeps its loaded grid, so an unchanged table inside
    /// rebuilt text is not measured and laid out from scratch, and a changed table
    /// at the same path updates only the cells that differ.
    @MainActor final class ReusableTables {
        private var attachments: [MarkdownTable: [MarkdownTableAttachment]] = [:]
        private var attachmentsByPath: [EditorNodePath: MarkdownTableAttachment] = [:]
        private var paths: [ObjectIdentifier: EditorNodePath] = [:]

        /// `blockDelta` moves the paths of the replaced text's attachments to the
        /// paths their blocks have after earlier blocks were inserted or removed.
        init(in text: NSAttributedString, range: NSRange, blockDelta: Int = 0) {
            text.enumerateAttribute(.attachment, in: range) { value, _, _ in
                if let attachment = value as? MarkdownTableAttachment, let reference = attachment.pathReference {
                    let path = reference.path.shiftingRootBlock(by: blockDelta)
                    attachments[attachment.table, default: []].append(attachment)
                    attachmentsByPath[path] = attachment
                    paths[ObjectIdentifier(attachment)] = path
                }
            }
        }

        /// Removes and returns an attachment showing `table`, or else the attachment
        /// at `path` updated to show it.
        func take(_ table: MarkdownTable, at path: EditorNodePath) -> MarkdownTableAttachment? {
            if let attachment = attachments[table]?.first {
                attachments[table]?.removeFirst()
                if let path = paths[ObjectIdentifier(attachment)], attachmentsByPath[path] === attachment {
                    attachmentsByPath[path] = nil
                }
                return attachment
            }
            guard let attachment = attachmentsByPath.removeValue(forKey: path) else {
                return nil
            }
            attachments[attachment.table]?.removeAll { $0 === attachment }
            attachment.controller.present(table)
            return attachment
        }
    }

    /// Renders a complete document. Full builds are reserved for structural or configuration changes.
    func build(
        document: MarkdownDocument,
        output: Output = .nativeText,
        theme: MarkdownEditorTheme = .basic,
        baseURL: URL? = nil,
        imageProvider: (any MarkdownEditorImageProvider)? = nil,
        onTableChange: ((EditorNodePath, MarkdownTable) -> Void)? = nil,
        tableSelection: ((EditorNodePath) -> MarkdownTableCellSelection?)? = nil,
        onTableSelectionChange: ((EditorNodePath, MarkdownTableCellSelection?) -> Void)? = nil,
        onImageChange: ((EditorNodePath, MarkdownImageMetadata) -> Void)? = nil
    ) -> DocumentProjection {
        build(
            document: document,
            output: output,
            theme: theme,
            baseURL: baseURL,
            imageProvider: imageProvider,
            callbacks: Callbacks(
                onTableChange: onTableChange,
                tableSelection: tableSelection,
                onTableSelectionChange: onTableSelectionChange,
                onImageChange: onImageChange
            )
        )
    }

    func build(
        document: MarkdownDocument,
        output: Output = .nativeText,
        theme: MarkdownEditorTheme,
        baseURL: URL?,
        imageProvider: (any MarkdownEditorImageProvider)?,
        callbacks: Callbacks,
        reusing tables: ReusableTables? = nil
    ) -> DocumentProjection {
        let fragment = build(
            blocks: document.blocks.indices,
            of: document,
            projectionOrigin: 0,
            sourceOrigin: 0,
            output: output,
            theme: theme,
            baseURL: baseURL,
            imageProvider: imageProvider,
            callbacks: callbacks,
            reusing: tables
        )
        return DocumentProjection(
            attributedString: fragment.attributedString,
            sourceDocument: document,
            index: ProjectionIndex(
                units: fragment.units,
                projectionUTF16Length: fragment.projectionLength,
                sourceUTF16Length: fragment.sourceLength
            )
        )
    }

    /// Renders consecutive top-level blocks exactly as they appear inside a full projection.
    ///
    /// Units are positioned from the given origins, so they can replace the units of
    /// the blocks previously rendered at those offsets.
    func build(
        blocks: Range<Int>,
        of document: MarkdownDocument,
        projectionOrigin: Int,
        sourceOrigin: Int,
        output: Output = .nativeText,
        theme: MarkdownEditorTheme,
        baseURL: URL?,
        imageProvider: (any MarkdownEditorImageProvider)?,
        callbacks: Callbacks,
        reusing tables: ReusableTables? = nil
    ) -> ProjectionFragment {
        let state = BuildState(
            output: output,
            theme: theme,
            baseURL: baseURL,
            imageProvider: imageProvider,
            callbacks: callbacks,
            reusableTables: tables,
            projectionOrigin: projectionOrigin,
            sourceOrigin: sourceOrigin
        )
        let root = EditorNodePath()
        for index in blocks {
            state.render(
                block: document.blocks[index],
                path: root.appending(.block(index)),
                firstPrefix: "",
                continuationPrefix: ""
            )
        }
        return ProjectionFragment(
            attributedString: state.projection,
            units: state.units,
            projectionLength: state.projectionLength - projectionOrigin,
            sourceLength: state.sourceLength - sourceOrigin
        )
    }
}

/// Native text and units rendered for a run of top-level blocks.
struct ProjectionFragment {
    var attributedString: NSAttributedString
    /// Units positioned at the fragment's place in the whole projection.
    var units: [ProjectionUnit]
    var projectionLength: Int
    var sourceLength: Int
}

/// Native paragraph presentation inherited through block containers.
private struct BlockPresentation {
    var quoteDepth = 0
    var listKind: MarkdownListKind?
    var textList: NSTextList?
    var taskState: MarkdownTaskState?

    func insideBlockquote() -> Self {
        var copy = self
        copy.quoteDepth += 1
        return copy
    }

    func inList(
        kind: MarkdownListKind,
        textList: NSTextList?,
        taskState: MarkdownTaskState?
    ) -> Self {
        var copy = self
        copy.listKind = kind
        copy.textList = textList
        copy.taskState = taskState
        return copy
    }
}

/// Mutable state used only while one full projection is built.
@MainActor private final class BuildState {
    /// Source offsets need only a length; canonical source is serialized from the document.
    private(set) var sourceLength = 0
    /// Accumulated native attributed text.
    let projection = NSMutableAttributedString(string: "")
    /// Completed replaceable leaf units.
    var units: [ProjectionUnit] = []

    private let output: MarkdownProjectionBuilder.Output
    private(set) var projectionLength = 0
    /// Offset of the first rendered character in the whole projection.
    private let projectionOrigin: Int
    private let theme: MarkdownEditorTheme
    private let baseURL: URL?
    private let imageProvider: (any MarkdownEditorImageProvider)?
    private let callbacks: MarkdownProjectionBuilder.Callbacks
    private let reusableTables: MarkdownProjectionBuilder.ReusableTables?
    private let identities = EditorIdentityTree()
    /// Inline attributes already resolved during this build, including converted fonts.
    private var attributesByStyle: [InlineStyle: [NSAttributedString.Key: Any]] = [:]

    init(
        output: MarkdownProjectionBuilder.Output,
        theme: MarkdownEditorTheme,
        baseURL: URL?,
        imageProvider: (any MarkdownEditorImageProvider)?,
        callbacks: MarkdownProjectionBuilder.Callbacks,
        reusableTables: MarkdownProjectionBuilder.ReusableTables?,
        projectionOrigin: Int,
        sourceOrigin: Int
    ) {
        self.output = output
        self.theme = theme
        self.baseURL = baseURL
        self.imageProvider = imageProvider
        self.callbacks = callbacks
        self.reusableTables = reusableTables
        self.projectionOrigin = projectionOrigin
        self.projectionLength = projectionOrigin
        self.sourceLength = sourceOrigin
    }

    func render(
        block: MarkdownBlock,
        path: EditorNodePath,
        firstPrefix: String,
        continuationPrefix: String,
        presentation: BlockPresentation = BlockPresentation()
    ) {
        switch block {
            case let .blockquote(blocks):
                for (index, child) in blocks.enumerated() {
                    render(
                        block: child,
                        path: path.appending(.blockquoteBlock(index)),
                        firstPrefix: firstPrefix + "> ",
                        continuationPrefix: continuationPrefix + "> ",
                        presentation: presentation.insideBlockquote()
                    )
                }
            case let .list(list):
                render(list: list, path: path, prefix: firstPrefix, presentation: presentation)
            case let .codeBlock(info, content):
                renderLeaf(path: path, kind: .codeBlock, presentation: presentation) {
                    let codeAttributes = attributes(for: InlineStyle().withCode())
                    let fence = Self.codeFence(for: content)
                    appendHidden(firstPrefix + fence + (info.map { " " + $0 } ?? "") + "\n")
                    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
                    for (index, line) in lines.enumerated() {
                        if index > 0 {
                            appendMapped(source: "\n", projection: "\n", attributes: codeAttributes)
                        }
                        if index > 0 || !line.isEmpty {
                            appendHidden(continuationPrefix)
                        }
                        let value = String(line)
                        appendMapped(source: value, projection: value, attributes: codeAttributes)
                    }
                    if !content.hasSuffix("\n") {
                        appendMapped(source: "\n", projection: "\n", attributes: codeAttributes)
                    }
                    appendHidden(continuationPrefix + fence)
                }
            case let .html(content):
                renderLeaf(path: path, kind: .htmlBlock, presentation: presentation) {
                    appendHidden(firstPrefix)
                    appendMapped(source: content, projection: content, attributes: attributes(for: InlineStyle().withCode()))
                }
            case let .paragraph(content):
                renderLeaf(path: path, kind: .paragraph, presentation: presentation) {
                    appendHidden(firstPrefix)
                    render(
                        inlines: content,
                        path: path,
                        continuationPrefix: continuationPrefix,
                        style: InlineStyle()
                    )
                }
            case let .heading(level, content):
                renderLeaf(path: path, kind: .heading(level), presentation: presentation) {
                    appendHidden(firstPrefix + String(repeating: "#", count: level.rawValue) + " ")
                    render(
                        inlines: content,
                        path: path,
                        continuationPrefix: continuationPrefix,
                        style: InlineStyle(headingLevel: level)
                    )
                }
            case let .table(table):
                renderLeaf(path: path, kind: .table, presentation: presentation) {
                    let markdown = Self.tableMarkdown(table, prefix: firstPrefix)
                    guard output == .nativeText else {
                        appendObjectPlaceholder(source: markdown, kind: "table")
                        return
                    }
                    let attachment = reusableTables?.take(table, at: path) ?? MarkdownTableAttachment(table: table)
                    let reference = attachment.pathReference ?? EditorPathReference(path)
                    reference.path = path
                    attachment.pathReference = reference
                    attachment.onChange = { [onTableChange = callbacks.onTableChange] table in
                        onTableChange?(reference.path, table)
                    }
                    if let onTableSelectionChange = callbacks.onTableSelectionChange {
                        attachment.controller.configureSelection(callbacks.tableSelection?(path)) { selection in
                            onTableSelectionChange(reference.path, selection)
                        }
                    }
                    appendAttachment(attachment, source: markdown, kind: "table")
                }
            case .thematicBreak:
                renderLeaf(path: path, kind: .thematicBreak, presentation: presentation) {
                    appendObjectPlaceholder(source: firstPrefix + "---", kind: "thematicBreak")
                }
        }
    }

    private func render(
        list: MarkdownList,
        path: EditorNodePath,
        prefix: String,
        presentation: BlockPresentation
    ) {
        let sharedTextList = output == .nativeText ? makeTextList(kind: list.kind) : nil
        for (itemIndex, item) in list.items.enumerated() {
            let marker = switch list.kind {
                case .unordered: "- "
                case let .ordered(start): "\(start + itemIndex). "
            }
            let taskMarker = switch item.taskState {
                case .checked?: "[x] "
                case .unchecked?: "[ ] "
                case nil: ""
            }
            let firstItemPrefix = prefix + marker + taskMarker
            let continuation = prefix + String(repeating: " ", count: marker.utf16.count + taskMarker.utf16.count)
            let itemPath = path.appending(.listItem(itemIndex))
            for (blockIndex, block) in item.blocks.enumerated() {
                render(
                    block: block,
                    path: itemPath.appending(.itemBlock(blockIndex)),
                    firstPrefix: blockIndex == 0 ? firstItemPrefix : continuation,
                    continuationPrefix: continuation,
                    presentation: presentation.inList(
                        kind: list.kind,
                        textList: sharedTextList,
                        taskState: item.taskState
                    )
                )
            }
        }
    }

    private func renderLeaf(
        path: EditorNodePath,
        kind: ProjectionUnit.Kind,
        presentation: BlockPresentation,
        body: () -> Void
    ) {
        let sourceStart = self.sourceLength
        let projectionStart = projectionLength

        body()

        appendMapped(source: "\n", projection: "\n", attributes: theme.bodyAttributes)

        let id = identities.id(for: path)
        let projectionRange = ProjectionUTF16Range(
            location: projectionStart,
            length: projectionLength - projectionStart
        )
        let sourceRange = SourceUTF16Range(
            location: sourceStart,
            length: self.sourceLength - sourceStart
        )
        let segments = pendingSegments
        pendingSegments = []
        units.append(
            ProjectionUnit(
                id: id,
                path: path,
                kind: kind,
                projectionRange: projectionRange,
                sourceRange: sourceRange,
                segments: segments
            )
        )
        if output == .nativeText, projectionRange.length > 0 {
            let range = NSRange(location: projectionRange.location - projectionOrigin, length: projectionRange.length)
            if let taskState = presentation.taskState {
                projection.addAttribute(.markdownEditorTaskChecked, value: NSNumber(value: taskState == .checked), range: range)
                if taskState == .checked {
                    projection.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            }
            projection.addAttribute(.markdownEditorNodeID, value: id.description, range: range)
            if let paragraphStyle = paragraphStyle(for: presentation) {
                projection.addAttribute(
                    .paragraphStyle,
                    value: paragraphStyle,
                    range: range
                )
            }
        }
    }

    /// Inputs that fully determine a block's paragraph style.
    private struct ParagraphStyleKey: Hashable {
        var quoteDepth: Int
        var isListItem: Bool
        var isTask: Bool
        /// Lists keep their text list alive through the cached style.
        var textList: ObjectIdentifier?
    }

    /// Paragraph styles shared by blocks with the same presentation.
    private var paragraphStyles: [ParagraphStyleKey: NSParagraphStyle] = [:]

    private func paragraphStyle(for presentation: BlockPresentation) -> NSParagraphStyle? {
        guard presentation.quoteDepth > 0 || presentation.listKind != nil else {
            return nil
        }
        let isTask = presentation.taskState != nil
        let textList = isTask ? nil : presentation.textList
        let key = ParagraphStyleKey(
            quoteDepth: presentation.quoteDepth,
            isListItem: presentation.listKind != nil,
            isTask: isTask,
            textList: textList.map(ObjectIdentifier.init)
        )
        if let style = paragraphStyles[key] {
            return style
        }
        let style = NSMutableParagraphStyle()
        let quoteIndent = CGFloat(presentation.quoteDepth) * 20
        style.headIndent = quoteIndent + (presentation.listKind == nil ? 0 : 24)
        style.firstLineHeadIndent = quoteIndent
        if isTask {
            let metrics = MarkdownTaskCheckboxLayer.Metrics(theme: theme)
            style.headIndent = quoteIndent + metrics.gutterWidth
            style.firstLineHeadIndent = style.headIndent
            style.paragraphSpacingBefore = metrics.paragraphSpacing
            style.paragraphSpacing = metrics.paragraphSpacing
        }
        if let textList {
            style.textLists = [textList]
        }
        paragraphStyles[key] = style
        return style
    }

    private func makeTextList(kind: MarkdownListKind) -> NSTextList {
        let markerFormat: NSTextList.MarkerFormat = switch kind {
            case .unordered: .disc
            case .ordered: NSTextList.MarkerFormat(rawValue: NSTextList.MarkerFormat.decimal.rawValue + ".")
        }
        let textList = NSTextList(markerFormat: markerFormat, options: 0)
        if case let .ordered(start) = kind {
            textList.startingItemNumber = start
        }
        return textList
    }

    /// Mapping segments owned by the current leaf until they move into its unit.
    private var pendingSegments: [OffsetMapSegment] = []

    private func render(
        inlines: [MarkdownInline],
        path: EditorNodePath,
        continuationPrefix: String,
        style: InlineStyle
    ) {
        for (index, inline) in inlines.enumerated() {
            render(
                inline: inline,
                path: path.appending(.inline(index)),
                continuationPrefix: continuationPrefix,
                style: style
            )
        }
    }

    private func render(
        inline: MarkdownInline,
        path: EditorNodePath,
        continuationPrefix: String,
        style: InlineStyle
    ) {
        switch inline {
            case let .text(value):
                appendEscapedText(value, attributes: attributes(for: style))
            case .softBreak:
                appendMapped(source: "\n", projection: "\n", attributes: attributes(for: style))
                appendHidden(continuationPrefix)
            case .lineBreak:
                appendHidden("\\")
                var lineBreakAttributes = attributes(for: style)
                lineBreakAttributes[.markdownEditorHardBreak] = true
                appendMapped(source: "\n", projection: "\n", attributes: lineBreakAttributes)
                appendHidden(continuationPrefix)
            case let .code(value):
                let delimiter = Self.inlineCodeDelimiter(for: value)
                appendHidden(delimiter)
                appendMapped(source: value, projection: value, attributes: attributes(for: style.withCode()))
                appendHidden(delimiter)
            case let .html(value):
                appendMapped(source: value, projection: value, attributes: attributes(for: style.withHTML()))
            case let .emphasis(children):
                appendHidden("*")
                render(children: children, path: path, continuationPrefix: continuationPrefix, style: style.withItalic())
                appendHidden("*")
            case let .strong(children):
                appendHidden("**")
                render(children: children, path: path, continuationPrefix: continuationPrefix, style: style.withBold())
                appendHidden("**")
            case let .strikethrough(children):
                appendHidden("~~")
                render(children: children, path: path, continuationPrefix: continuationPrefix, style: style.withStrikethrough())
                appendHidden("~~")
            case let .link(destination, title, children):
                appendHidden("[")
                render(
                    children: children,
                    path: path,
                    continuationPrefix: continuationPrefix,
                    style: style.withLink(destination: destination, title: title)
                )
                appendHidden("](" + Self.linkDestination(destination) + Self.titleSuffix(title) + ")")
            case let .image(source, title, children):
                let alt = Self.inlineMarkdown(children)
                guard output == .nativeText else {
                    appendObjectPlaceholder(
                        source: "![" + alt + "](" + Self.linkDestination(source) + Self.titleSuffix(title) + ")",
                        kind: "image"
                    )
                    return
                }
                let metadata = MarkdownImageMetadata(source: source, title: title, altText: MarkdownImageMetadata.altText(for: children))
                let reference = EditorPathReference(path)
                let attachment = MarkdownImageAttachment(
                    metadata: metadata,
                    baseURL: baseURL,
                    imageProvider: imageProvider
                ) { [onImageChange = callbacks.onImageChange] metadata in
                    onImageChange?(reference.path, metadata)
                }
                attachment.pathReference = reference
                attachment.altContent = children
                appendAttachment(
                    attachment,
                    source: "![" + alt + "](" + Self.linkDestination(source) + Self.titleSuffix(title) + ")",
                    kind: "image",
                    attributes: attributes(for: style)
                )
        }
    }

    private func render(
        children: [MarkdownInline],
        path: EditorNodePath,
        continuationPrefix: String,
        style: InlineStyle
    ) {
        for (index, child) in children.enumerated() {
            render(
                inline: child,
                path: path.appending(.inlineChild(index)),
                continuationPrefix: continuationPrefix,
                style: style
            )
        }
    }

    private func appendHidden(_ value: String) {
        guard !value.isEmpty else {
            return
        }
        let sourceStart = self.sourceLength
        sourceLength += value.utf16.count
        pendingSegments.append(
            OffsetMapSegment(
                projectionRange: ProjectionUTF16Range(location: projectionLength, length: 0),
                sourceRange: SourceUTF16Range(location: sourceStart, length: value.utf16.count),
                kind: .hiddenSource
            )
        )
    }

    private func appendEscapedText(
        _ value: String,
        attributes: [NSAttributedString.Key: Any]
    ) {
        var runStart = value.startIndex
        for index in value.indices {
            let character = value[index]
            let needsEscape = Self.markdownEscapablePunctuation.contains(character)
            // Preserve the distinct mapping kind of a literal object-replacement character.
            let isObject = character == "\u{fffc}"
            guard needsEscape || isObject else {
                continue
            }
            if runStart < index {
                let run = String(value[runStart ..< index])
                appendMapped(source: run, projection: run, attributes: attributes)
            }
            if needsEscape {
                appendHidden("\\")
            }
            runStart = index
            if isObject {
                appendMapped(source: "\u{fffc}", projection: "\u{fffc}", attributes: attributes)
                runStart = value.index(after: index)
            }
        }
        if runStart < value.endIndex {
            let run = String(value[runStart...])
            appendMapped(source: run, projection: run, attributes: attributes)
        }
    }

    private func appendMapped(
        source sourceValue: String,
        projection projectionValue: String,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard !sourceValue.isEmpty || !projectionValue.isEmpty else {
            return
        }
        let sourceStart = self.sourceLength
        let projectionStart = projectionLength
        if output == .nativeText {
            projection.append(NSAttributedString(string: projectionValue, attributes: attributes))
        }
        let sourceLength = sourceValue.utf16.count
        self.sourceLength += sourceLength
        let projectionLength = projectionValue.utf16.count
        self.projectionLength += projectionLength
        let kind: OffsetMapSegment.Kind = projectionLength == 1 && projectionValue == "\u{fffc}"
            ? .objectReplacement
            : .text
        pendingSegments.append(
            OffsetMapSegment(
                projectionRange: ProjectionUTF16Range(location: projectionStart, length: projectionLength),
                sourceRange: SourceUTF16Range(location: sourceStart, length: sourceLength),
                kind: kind
            )
        )
    }

    private func appendAttachment(
        _ attachment: NSTextAttachment,
        source sourceValue: String,
        kind: String,
        attributes: [NSAttributedString.Key: Any] = [:]
    ) {
        let sourceStart = self.sourceLength
        let projectionStart = projectionLength
        sourceLength += sourceValue.utf16.count
        let attributedString = NSMutableAttributedString(attachment: attachment)
        attributedString.addAttributes(
            theme.objectPlaceholderAttributes
                .merging(attributes) { _, rhs in rhs }
                .merging([.markdownEditorObjectKind: kind]) { _, rhs in rhs },
            range: NSRange(location: 0, length: attributedString.length)
        )
        projection.append(attributedString)
        projectionLength += 1
        pendingSegments.append(
            OffsetMapSegment(
                projectionRange: ProjectionUTF16Range(location: projectionStart, length: 1),
                sourceRange: SourceUTF16Range(location: sourceStart, length: sourceValue.utf16.count),
                kind: .objectReplacement
            )
        )
    }

    private func appendObjectPlaceholder(source sourceValue: String, kind: String) {
        let sourceStart = self.sourceLength
        let projectionStart = projectionLength
        sourceLength += sourceValue.utf16.count
        if output == .nativeText {
            projection.append(
                NSAttributedString(
                    string: "\u{fffc}",
                    attributes: theme.objectPlaceholderAttributes.merging([.markdownEditorObjectKind: kind]) { _, rhs in rhs }
                )
            )
        }
        projectionLength += 1
        pendingSegments.append(
            OffsetMapSegment(
                projectionRange: ProjectionUTF16Range(location: projectionStart, length: 1),
                sourceRange: SourceUTF16Range(location: sourceStart, length: sourceValue.utf16.count),
                kind: .objectReplacement
            )
        )
    }
}

/// Rendering attributes inherited while walking nested inline nodes.
private struct InlineStyle: Hashable {
    var isBold = false
    var isItalic = false
    var isCode = false
    var isHTML = false
    var isStrikethrough = false
    var linkDestination: String?
    var linkTitle: String?
    var headingLevel: MarkdownHeadingLevel?

    init(headingLevel: MarkdownHeadingLevel? = nil) {
        self.headingLevel = headingLevel
    }

    func withBold() -> Self {
        changing(\.isBold, to: true)
    }

    func withItalic() -> Self {
        changing(\.isItalic, to: true)
    }

    func withCode() -> Self {
        changing(\.isCode, to: true)
    }

    func withHTML() -> Self {
        changing(\.isHTML, to: true)
    }

    func withStrikethrough() -> Self {
        changing(\.isStrikethrough, to: true)
    }

    func withLink(destination: String, title: String?) -> Self {
        var copy = self
        copy.linkDestination = destination
        copy.linkTitle = title
        return copy
    }

    private func changing<Value>(_ keyPath: WritableKeyPath<Self, Value>, to value: Value) -> Self {
        var copy = self
        copy[keyPath: keyPath] = value
        return copy
    }
}

private extension BuildState {
    static let markdownEscapablePunctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    /// Attributes for an inline style, resolved once per build.
    func attributes(for style: InlineStyle) -> [NSAttributedString.Key: Any] {
        if let attributes = attributesByStyle[style] {
            return attributes
        }
        let attributes = makeAttributes(for: style)
        attributesByStyle[style] = attributes
        return attributes
    }

    private func makeAttributes(for style: InlineStyle) -> [NSAttributedString.Key: Any] {
        guard output == .nativeText else {
            return [:]
        }
        var result: [NSAttributedString.Key: Any] = if style.isCode {
            theme.codeAttributes
        } else if let headingLevel = style.headingLevel {
            theme.headingAttributes[headingLevel] ?? theme.bodyAttributes
        } else {
            theme.bodyAttributes
        }
        if style.linkDestination != nil {
            result.merge(theme.linkAttributes) { _, replacement in replacement }
        }
        if style.isBold {
            result[.markdownEditorStrong] = true
        }
        if style.isItalic {
            result[.markdownEditorEmphasis] = true
        }
        if style.isCode {
            result[.markdownEditorCode] = true
        }
        if style.isHTML {
            result[.markdownEditorInlineHTML] = true
        }
        if style.isStrikethrough {
            result[.markdownEditorStrikethrough] = true
        }
        if let destination = style.linkDestination {
            result[.markdownEditorLinkDestination] = destination
            result[.link] = destination
        }
        if let title = style.linkTitle {
            result[.markdownEditorLinkTitle] = title
        }

        #if canImport(UIKit)
            guard let font = result[.font] as? UIFont else {
                return result
            }
            var descriptor = font.fontDescriptor
            if style.isItalic, let italic = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) {
                descriptor = italic
            }
            let traits = descriptor.symbolicTraits
            let hasBoldTrait = traits.contains(.traitBold)
            let wantsBold = style.isBold || style.headingLevel != nil
            if wantsBold && !hasBoldTrait {
                descriptor = UIFont.systemFont(ofSize: font.pointSize, weight: .bold).fontDescriptor.withSymbolicTraits(
                    descriptor.symbolicTraits.union(.traitBold)
                ) ?? descriptor
            }
            result[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
            if style.isStrikethrough {
                result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            return result
        #elseif canImport(AppKit)
            guard var font = result[.font] as? NSFont else {
                return result
            }
            let wantsBold = style.isBold || style.headingLevel != nil
            if wantsBold {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if style.isItalic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            result[.font] = font
            if style.isStrikethrough {
                result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            return result
        #else
            return result
        #endif
    }

    static func inlineCodeDelimiter(for value: String) -> String {
        var longestRun = 0
        var currentRun = 0
        for character in value {
            if character == "`" {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return String(repeating: "`", count: longestRun + 1)
    }

    static func codeFence(for value: String) -> String {
        var longestRun = 2
        var currentRun = 0
        for character in value {
            if character == "`" {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return String(repeating: "`", count: longestRun + 1)
    }

    static func linkDestination(_ destination: String) -> String {
        destination.contains(where: \.isWhitespace) ? "<\(destination)>" : destination
    }

    static func titleSuffix(_ title: String?) -> String {
        guard let title else {
            return ""
        }
        return " \"" + title.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func inlineMarkdown(_ inlines: [MarkdownInline]) -> String {
        inlines.map { inline in
            switch inline {
                case let .text(value): value
                case .softBreak: "\n"
                case .lineBreak: "\\\n"
                case let .code(value): "`" + value + "`"
                case let .html(value): value
                case let .emphasis(children): "*" + inlineMarkdown(children) + "*"
                case let .strong(children): "**" + inlineMarkdown(children) + "**"
                case let .strikethrough(children): "~~" + inlineMarkdown(children) + "~~"
                case let .link(destination, title, children):
                    "[" + inlineMarkdown(children) + "](" + linkDestination(destination) + titleSuffix(title) + ")"
                case let .image(source, title, children):
                    "![" + inlineMarkdown(children) + "](" + linkDestination(source) + titleSuffix(title) + ")"
            }
        }.joined()
    }

    static func tableMarkdown(_ table: MarkdownTable, prefix: String) -> String {
        let columnCount = max(table.alignments.count, table.header.cells.count, table.rows.map(\.cells.count).max() ?? 0)
        guard columnCount > 0 else {
            return prefix + "| |"
        }

        func row(_ cells: [MarkdownTableCell]) -> String {
            let values = (0 ..< columnCount).map { index in
                guard index < cells.count else {
                    return ""
                }
                return inlineMarkdown(cells[index].content)
                    .replacingOccurrences(of: "|", with: "\\|")
                    .replacingOccurrences(of: "\n", with: " ")
            }
            return prefix + "| " + values.joined(separator: " | ") + " |"
        }

        let delimiter = (0 ..< columnCount).map { index in
            let alignment = index < table.alignments.count ? table.alignments[index] : .none
            return switch alignment {
                case .none: "---"
                case .left: ":---"
                case .center: ":---:"
                case .right: "---:"
            }
        }
        var lines = [row(table.header.cells)]
        lines.append(prefix + "| " + delimiter.joined(separator: " | ") + " |")
        lines.append(contentsOf: table.rows.map { row($0.cells) })
        return lines.joined(separator: "\n")
    }
}
