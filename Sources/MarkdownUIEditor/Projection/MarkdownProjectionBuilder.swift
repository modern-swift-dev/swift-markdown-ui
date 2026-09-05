import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension NSAttributedString.Key {
    static let markdownEditorNodeID = NSAttributedString.Key("MarkdownUIEditor.NodeID")
    static let markdownEditorNodePath = NSAttributedString.Key("MarkdownUIEditor.NodePath")
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
        return true
    }
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
        let state = BuildState(
            output: output,
            theme: theme,
            baseURL: baseURL,
            imageProvider: imageProvider,
            onTableChange: onTableChange,
            tableSelection: tableSelection,
            onTableSelectionChange: onTableSelectionChange,
            onImageChange: onImageChange
        )
        let root = EditorNodePath()
        for (index, block) in document.blocks.enumerated() {
            state.render(
                block: block,
                path: root.appending(.block(index)),
                firstPrefix: "",
                continuationPrefix: ""
            )
        }
        let attributedString: NSAttributedString = state.projection
        return DocumentProjection(
            attributedString: attributedString,
            sourceDocument: document,
            index: ProjectionIndex(
                units: state.units,
                projectionUTF16Length: state.projectionLength,
                sourceUTF16Length: state.sourceLength
            )
        )
    }
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
    private let theme: MarkdownEditorTheme
    private let baseURL: URL?
    private let imageProvider: (any MarkdownEditorImageProvider)?
    private let onTableChange: ((EditorNodePath, MarkdownTable) -> Void)?
    private let tableSelection: ((EditorNodePath) -> MarkdownTableCellSelection?)?
    private let onTableSelectionChange: ((EditorNodePath, MarkdownTableCellSelection?) -> Void)?
    private let onImageChange: ((EditorNodePath, MarkdownImageMetadata) -> Void)?
    private let identities = EditorIdentityTree()

    init(
        output: MarkdownProjectionBuilder.Output,
        theme: MarkdownEditorTheme,
        baseURL: URL?,
        imageProvider: (any MarkdownEditorImageProvider)?,
        onTableChange: ((EditorNodePath, MarkdownTable) -> Void)?,
        tableSelection: ((EditorNodePath) -> MarkdownTableCellSelection?)?,
        onTableSelectionChange: ((EditorNodePath, MarkdownTableCellSelection?) -> Void)?,
        onImageChange: ((EditorNodePath, MarkdownImageMetadata) -> Void)?
    ) {
        self.output = output
        self.theme = theme
        self.baseURL = baseURL
        self.imageProvider = imageProvider
        self.onTableChange = onTableChange
        self.tableSelection = tableSelection
        self.onTableSelectionChange = onTableSelectionChange
        self.onImageChange = onImageChange
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
                    let attachment = MarkdownTableAttachment(table: table) { [onTableChange] table in
                        onTableChange?(path, table)
                    }
                    if let onTableSelectionChange {
                        attachment.controller.configureSelection(tableSelection?(path)) { selection in
                            onTableSelectionChange(path, selection)
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
            if let taskState = presentation.taskState {
                projection.addAttribute(.markdownEditorTaskChecked, value: NSNumber(value: taskState == .checked), range: projectionRange.nsRange)
                if taskState == .checked {
                    projection.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: projectionRange.nsRange)
                }
            }
            projection.addAttributes(
                [
                    .markdownEditorNodeID: id.description,
                    .markdownEditorNodePath: path.description
                ],
                range: projectionRange.nsRange
            )
            if let paragraphStyle = paragraphStyle(for: presentation) {
                projection.addAttribute(
                    .paragraphStyle,
                    value: paragraphStyle,
                    range: projectionRange.nsRange
                )
            }
        }
    }

    private func paragraphStyle(for presentation: BlockPresentation) -> NSParagraphStyle? {
        guard presentation.quoteDepth > 0 || presentation.listKind != nil else {
            return nil
        }
        let style = NSMutableParagraphStyle()
        let quoteIndent = CGFloat(presentation.quoteDepth) * 20
        style.headIndent = quoteIndent + (presentation.listKind == nil ? 0 : 24)
        style.firstLineHeadIndent = quoteIndent
        if presentation.taskState != nil {
            let metrics = MarkdownTaskCheckboxLayer.Metrics(theme: theme)
            style.headIndent = quoteIndent + metrics.gutterWidth
            style.firstLineHeadIndent = style.headIndent
            style.paragraphSpacingBefore = metrics.paragraphSpacing
            style.paragraphSpacing = metrics.paragraphSpacing
        }
        if let textList = presentation.textList, presentation.taskState == nil {
            style.textLists = [textList]
        }
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
                let attachment = MarkdownImageAttachment(
                    metadata: metadata,
                    baseURL: baseURL,
                    imageProvider: imageProvider
                ) { [onImageChange] metadata in
                    onImageChange?(path, metadata)
                }
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
private struct InlineStyle {
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

    func attributes(for style: InlineStyle) -> [NSAttributedString.Key: Any] {
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
