import Foundation

/// A protocol that represents any Markdown content.
public protocol MarkdownContentProtocol: Sendable {
    var _markdownContent: MarkdownContent { get }
}

/// A Markdown content value.
///
/// A Markdown content value consists of a sequence of blocks – structural elements like paragraphs, blockquotes, lists,
/// headings, thematic breaks, and code blocks. Some blocks, like blockquotes and list items, contain other blocks; others,
/// like headings and paragraphs, have inline text, links, emphasized text, etc.
///
/// You can create a Markdown content value by passing a Markdown-formatted string to ``init(_:)``.
///
/// ```swift
/// let content = MarkdownContent("You can try **CommonMark** [here](https://spec.commonmark.org/dingus/).")
/// ```
///
/// Alternatively, you can build a Markdown content value using a domain-specific language for blocks and inline text.
///
/// ```swift
/// let content = MarkdownContent {
///   Paragraph {
///     "You can try "
///     Strong("CommonMark")
///     SoftBreak()
///     InlineLink("here", destination: URL(string: "https://spec.commonmark.org/dingus/")!)
///     "."
///   }
/// }
/// ```
///
/// Once you have created a Markdown content value, you can display it using a ``MarkdownView``.
///
/// ```swift
/// var body: some View {
///   MarkdownView(self.content)
/// }
/// ```
///
/// A Markdown view also offers initializers that take a Markdown-formatted string ``MarkdownView/init(_:baseURL:imageBaseURL:)-(String,_,_)``,
/// or a Markdown content builder ``MarkdownView/init(baseURL:imageBaseURL:content:)``, so you don't need to create a
/// Markdown content value before displaying it.
///
/// ```swift
/// var body: some View {
///   VStack {
///     MarkdownView("You can try **CommonMark** [here](https://spec.commonmark.org/dingus/).")
///     MarkdownView {
///       Paragraph {
///         "You can try "
///         Strong("CommonMark")
///         SoftBreak()
///         InlineLink("here", destination: URL(string: "https://spec.commonmark.org/dingus/")!)
///         "."
///       }
///     }
///   }
/// }
/// ```
public struct MarkdownContent: Equatable, MarkdownContentProtocol {
    /// Returns a Markdown content value with the sum of the contents of all the container blocks
    /// present in this content.
    ///
    /// You can use this property to access the contents of a blockquote or a list. Returns `nil` if
    /// there are no container blocks.
    public var childContent: MarkdownContent? {
        let children = self.blocks.map(\.children).flatMap(\.self)
        return children.isEmpty ? nil : .init(blocks: children)
    }

    public var _markdownContent: MarkdownContent {
        self
    }

    let blocks: [BlockNode]
    enum ColorSchemeImageIndex: Sendable {
        case known([Int])
        case deferred
    }

    let colorSchemeImageIndex: ColorSchemeImageIndex

    /// Style configurations rarely render their content again, and builder elements are
    /// usually nested in other content. Defer their metadata scan until a caller actually
    /// uses the content in a Markdown view.
    var colorSchemeImageBlockIndices: [Int] {
        switch self.colorSchemeImageIndex {
            case let .known(indices):
                indices
            case .deferred:
                self.blocks.indices.filter { self.blocks[$0].containsColorSchemeImages }
        }
    }

    init(blocks: [BlockNode] = []) {
        self.blocks = blocks
        self.colorSchemeImageIndex = .known(blocks.indices.filter { blocks[$0].containsColorSchemeImages })
    }

    /// Creates a content value whose conditional-image block indices are already known.
    init(blocks: [BlockNode], colorSchemeImageBlockIndices: [Int]) {
        self.blocks = blocks
        self.colorSchemeImageIndex = .known(colorSchemeImageBlockIndices)
    }

    init(block: BlockNode) {
        self.init(blocks: [block])
    }

    init(configurationBlocks: [BlockNode]) {
        self.blocks = configurationBlocks
        self.colorSchemeImageIndex = .deferred
    }

    init(configurationBlock: BlockNode) {
        self.init(configurationBlocks: [configurationBlock])
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.blocks == rhs.blocks
    }

    /// Combines builder components, reusing their conditional-image indices when all are known.
    init(_ components: [MarkdownContentProtocol]) {
        var blocks: [BlockNode] = []
        var indices: [Int]? = []
        for component in components {
            let content = component._markdownContent
            if case let .known(known) = content.colorSchemeImageIndex {
                indices?.append(contentsOf: known.map { $0 + blocks.count })
            } else {
                indices = nil
            }
            blocks.append(contentsOf: content.blocks)
        }
        self.blocks = blocks
        self.colorSchemeImageIndex = indices.map(ColorSchemeImageIndex.known) ?? .deferred
    }

    /// Creates a Markdown content value from a Markdown-formatted string.
    /// - Parameter markdown: A Markdown-formatted string.
    public init(_ markdown: String) {
        self.init(blocks: .init(markdown: markdown))
    }

    /// Creates a Markdown content value composed of any number of blocks.
    /// - Parameter content: A Markdown content builder that returns the blocks that form the Markdown content.
    public init(@MarkdownContentBuilder content: () -> MarkdownContent) {
        self = content().resolvingColorSchemeImageIndex()
    }

    /// Scans deferred content once so that views rendering it do not rescan it.
    func resolvingColorSchemeImageIndex() -> MarkdownContent {
        guard case .deferred = self.colorSchemeImageIndex else {
            return self
        }
        return .init(blocks: self.blocks)
    }

    /// Renders this Markdown content value as a Markdown-formatted text.
    public func renderMarkdown() -> String {
        let result = self.blocks.renderMarkdown()
        return result.hasSuffix("\n") ? String(result.dropLast()) : result
    }

    /// Renders this Markdown content value as plain text.
    public func renderPlainText() -> String {
        let result = self.blocks.renderPlainText()
        return result.hasSuffix("\n") ? String(result.dropLast()) : result
    }

    /// Renders this Markdown content value as HTML code.
    public func renderHTML() -> String {
        self.blocks.renderHTML()
    }
}
