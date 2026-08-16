import SwiftUI

extension Sequence<InlineNode> {
    func renderText(
        baseURL: URL?,
        textStyles: InlineTextStyles,
        images: [String: Image],
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
        return renderer.result
    }
}

private struct TextInlineRenderer {
    var result = Text("")

    private let baseURL: URL?
    private let textStyles: InlineTextStyles
    private let images: [String: Image]
    private let softBreakMode: SoftBreak.Mode
    private let attributes: AttributeContainer
    private var shouldSkipNextWhitespace = false

    init(
        baseURL: URL?,
        textStyles: InlineTextStyles,
        images: [String: Image],
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

    private mutating func render(_ inline: InlineNode) {
        switch inline {
            case let .text(content):
                self.renderText(content)
            case .softBreak:
                self.renderSoftBreak()
            case let .html(content):
                self.renderHTML(content)
            case let .image(source, _):
                self.renderImage(source)
            default:
                self.defaultRender(inline)
        }
    }

    private mutating func renderText(_ text: String) {
        var text = text

        if self.shouldSkipNextWhitespace {
            self.shouldSkipNextWhitespace = false
            text = text.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
        }

        self.defaultRender(.text(text))
    }

    private mutating func renderSoftBreak() {
        switch self.softBreakMode {
            case .space where self.shouldSkipNextWhitespace:
                self.shouldSkipNextWhitespace = false
            case .space:
                self.defaultRender(.softBreak)
            case .lineBreak:
                self.shouldSkipNextWhitespace = true
                self.defaultRender(.lineBreak)
        }
    }

    private mutating func renderHTML(_ html: String) {
        let tag = HTMLTag(html)

        switch tag?.name.lowercased() {
            case "br":
                self.defaultRender(.lineBreak)
                self.shouldSkipNextWhitespace = true
            default:
                self.defaultRender(.html(html))
        }
    }

    private mutating func renderImage(_ source: String) {
        if let image = self.images[source] {
            let result = self.result
            self.result = result + Text(image)
        }
    }

    private mutating func defaultRender(_ inline: InlineNode) {
        let result = self.result
        self.result = result + Text(
            inline.renderAttributedString(
                baseURL: self.baseURL,
                textStyles: self.textStyles,
                softBreakMode: self.softBreakMode,
                attributes: self.attributes
            )
        )
    }
}
