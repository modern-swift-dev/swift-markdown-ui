import SwiftUI

extension Sequence<InlineNode> {
    func renderText(
        baseURL: URL?,
        textStyles: InlineTextStyles,
        images: [RawImageData: Image],
        softBreakMode: SoftBreak.Mode,
        attributes: AttributeContainer
    ) -> Text {
        var renderer = TextInlineRenderer(
            baseURL: baseURL,
            textStyles: textStyles,
            images: images,
            softBreakMode: softBreakMode,
            attributes: attributes
        )
        renderer.render(self)
        return renderer.finish()
    }
}

struct TextInlineRenderer {
    private var result = Text("")
    private var pendingText = AttributedString()
    private(set) var textChunkCount = 0

    private let baseURL: URL?
    private let textStyles: InlineTextStyles
    private let images: [RawImageData: Image]
    private let softBreakMode: SoftBreak.Mode
    private var attributes: AttributeContainer
    private var shouldSkipNextWhitespace = false

    init(
        baseURL: URL?,
        textStyles: InlineTextStyles,
        images: [RawImageData: Image],
        softBreakMode: SoftBreak.Mode,
        attributes: AttributeContainer
    ) {
        self.baseURL = baseURL
        self.textStyles = textStyles
        self.images = images
        self.softBreakMode = softBreakMode
        self.attributes = attributes
    }

    mutating func render(_ inlines: some Sequence<InlineNode>) {
        for inline in inlines {
            self.render(inline)
        }
    }

    mutating func finish() -> Text {
        self.flushText()
        return self.result
    }

    private mutating func render(_ inline: InlineNode) {
        switch inline {
            case let .text(content):
                self.renderText(content)
            case .softBreak:
                self.renderSoftBreak()
            case .lineBreak:
                self.renderLineBreak()
            case let .code(content):
                self.renderCode(content)
            case let .html(content):
                self.renderHTML(content)
            case let .emphasis(children):
                self.renderStyled(children, style: self.textStyles.emphasis)
            case let .strong(children):
                self.renderStyled(children, style: self.textStyles.strong)
            case let .strikethrough(children):
                self.renderStyled(children, style: self.textStyles.strikethrough)
            case let .link(destination, children):
                self.renderLink(destination: destination, children: children)
            case let .image(source, children):
                self.renderImage(source: source, children: children)
        }
    }

    private mutating func renderText(_ text: String) {
        var text = text

        if self.shouldSkipNextWhitespace {
            self.shouldSkipNextWhitespace = false
            text = text.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
        }

        self.append(text)
    }

    private mutating func renderSoftBreak() {
        switch self.softBreakMode {
            case .space where self.shouldSkipNextWhitespace:
                self.shouldSkipNextWhitespace = false
            case .space:
                self.append(" ")
            case .lineBreak:
                self.renderLineBreak()
        }
    }

    private mutating func renderLineBreak() {
        self.append("\n")
        self.shouldSkipNextWhitespace = true
    }

    private mutating func renderCode(_ code: String) {
        self.shouldSkipNextWhitespace = false
        let savedAttributes = self.attributes
        self.attributes = self.textStyles.code.mergingAttributes(self.attributes)
        self.append(code)
        self.attributes = savedAttributes
    }

    private mutating func renderHTML(_ html: String) {
        let tag = HTMLTag(html)

        switch tag?.name.lowercased() {
            case "br":
                self.renderLineBreak()
            default:
                self.renderText(html)
        }
    }

    private mutating func renderStyled(_ children: [InlineNode], style: TextStyle) {
        let savedAttributes = self.attributes
        self.attributes = style.mergingAttributes(self.attributes)
        self.render(children)
        self.attributes = savedAttributes
    }

    private mutating func renderLink(destination: String, children: [InlineNode]) {
        let savedAttributes = self.attributes
        self.attributes = self.textStyles.link.mergingAttributes(self.attributes)
        self.attributes.link = URL(string: destination, relativeTo: self.baseURL)
        self.render(children)
        self.attributes = savedAttributes
    }

    private mutating func renderImage(source: String, children: [InlineNode]) {
        let data = RawImageData(source: source, alt: children.renderPlainText())

        if let image = self.images[data] {
            self.shouldSkipNextWhitespace = false
            self.flushText()
            self.result = self.result.appending(Text(image))
        } else {
            self.renderText(data.alt)
        }
    }

    private mutating func append(_ text: String) {
        self.pendingText.append(AttributedString(text, attributes: self.attributes))
    }

    private mutating func flushText() {
        guard !self.pendingText.characters.isEmpty else {
            return
        }
        self.result = self.result.appending(Text(self.pendingText.resolvingFonts()))
        self.pendingText = AttributedString()
        self.textChunkCount += 1
    }
}

private extension Text {
    func appending(_ text: Text) -> Text {
        self + text
    }
}

private extension TextStyle {
    func mergingAttributes(_ attributes: AttributeContainer) -> AttributeContainer {
        var newAttributes = attributes
        self._collectAttributes(in: &newAttributes)
        return newAttributes
    }
}
