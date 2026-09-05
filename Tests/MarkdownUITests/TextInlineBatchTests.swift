#if os(iOS) || os(macOS)
@testable import MarkdownUI
import SwiftUI
import XCTest

@MainActor final class TextInlineBatchTests: XCTestCase {
    private let baseURL = URL(string: "https://example.com/docs/")!

    private var attributes: AttributeContainer {
        var attributes = AttributeContainer()
        attributes.fontProperties = FontProperties(size: 17)
        attributes.foregroundColor = .black
        return attributes
    }

    private var styles: InlineTextStyles {
        InlineTextStyles(
            code: FontFamilyVariant(.monospaced),
            emphasis: FontStyle(.italic),
            strong: FontWeight(.bold),
            strikethrough: StrikethroughStyle(.single),
            link: ForegroundColor(.blue)
        )
    }

    func testThousandsOfStyledNodesProduceOneTextChunk() {
        let nodes: [InlineNode] = (0 ..< 1000).flatMap { index in
            [.text("item \(index) "), .strong(children: [.text("bold")]), .softBreak]
        }
        var renderer = makeRenderer()
        renderer.render(nodes)
        let actual = renderer.finish()

        var expected = AttributedString()
        for index in 0 ..< 1000 {
            expected.append(AttributedString("item \(index) ", attributes: attributes))
            expected.append(AttributedString("bold", attributes: styledAttributes(weight: .bold)))
            expected.append(AttributedString(" ", attributes: attributes))
        }
        XCTAssertEqual(renderer.textChunkCount, 1)
        XCTAssertEqual(actual, Text("") + Text(expected.resolvingFonts()))
        XCTAssertEqual(renderer.finish(), actual, "Finishing twice must not append the pending text again")
        XCTAssertEqual(renderer.textChunkCount, 1)
    }

    func testNestedStylesAndLinksMatchIndividualTextFragments() throws {
        let nodes: [InlineNode] = [
            .text("Before "),
            .strong(children: [.text("bold "), .emphasis(children: [.text("both")])]),
            .text(" "),
            .link(destination: "guide", children: [.text("guide "), .code("value")]),
            .text(" "),
            .strikethrough(children: [.text("old")])
        ]
        var link = attributes
        link.foregroundColor = .blue
        link.link = URL(string: "guide", relativeTo: baseURL)
        var linkedCode = link
        linkedCode.fontProperties = FontProperties(familyVariant: .monospaced, size: 17)
        var strike = attributes
        strike.strikethroughStyle = .single
        let fragments: [(String, AttributeContainer)] = [
            ("Before ", attributes), ("bold ", styledAttributes(weight: .bold)),
            ("both", styledAttributes(style: .italic, weight: .bold)), (" ", attributes),
            ("guide ", link), ("value", linkedCode), (" ", attributes), ("old", strike)
        ]
        var renderer = makeRenderer()
        renderer.render(nodes)
        let actual = renderer.finish()
        var expected = AttributedString()
        for (text, attributes) in fragments {
            expected.append(AttributedString(text, attributes: attributes))
        }
        // Text equality additionally checks retained link/attribute semantics that pixels cannot show.
        XCTAssertEqual(actual, Text("") + Text(expected.resolvingFonts()))
        try assertSamePixels(actual, legacyText(fragments))
        XCTAssertEqual(renderer.textChunkCount, 1)
    }

    func testLineBreakWhitespaceCodeAndMissingImageRemainEquivalent() throws {
        let nodes: [InlineNode] = [
            .text("first"), .lineBreak, .text("  second"), .softBreak,
            .text("  third"), .html("<br />"), .code("  code"),
            .lineBreak, .image(source: "missing.png", children: [.text("  fallback")]),
            .html("<span>literal</span>")
        ]
        var code = attributes
        code.fontProperties = FontProperties(familyVariant: .monospaced, size: 17)
        for mode in [SoftBreak.Mode.space, .lineBreak] {
            var renderer = makeRenderer(softBreakMode: mode)
            renderer.render(nodes)
            let fragments: [(String, AttributeContainer)] = [
                ("first", attributes), ("\n", attributes), ("second", attributes),
                (mode == .space ? " " : "\n", attributes),
                (mode == .space ? "  third" : "third", attributes),
                ("\n", attributes), ("  code", code), ("\n", attributes),
                ("fallback", attributes), ("<span>literal</span>", attributes)
            ]
            try assertSamePixels(renderer.finish(), legacyText(fragments))
            XCTAssertEqual(renderer.textChunkCount, 1)
        }
    }

    func testLoadedImagesSplitChunksAndKeepSurroundingTextOrder() throws {
        let image = Image(systemName: "star.fill")
        let data = RawImageData(source: "star", alt: "star")
        let nodes: [InlineNode] = [
            .text("before "), .image(source: "star", children: [.text("star")]),
            .strong(children: [.text(" middle ")]),
            .image(source: "missing", children: [.text("fallback")]),
            .image(source: "star", children: [.text("star")]), .text(" after")
        ]
        var renderer = makeRenderer(images: [data: image])
        renderer.render(nodes)
        let expected = legacyText([("before ", attributes)]) + Text(image)
            + legacyText([(" middle ", styledAttributes(weight: .bold)), ("fallback", attributes)])
            + Text(image) + legacyText([(" after", attributes)])
        try assertSamePixels(renderer.finish(), expected)
        XCTAssertEqual(renderer.textChunkCount, 3)
    }

    private func makeRenderer(
        images: [RawImageData: Image] = [:],
        softBreakMode: SoftBreak.Mode = .space
    ) -> TextInlineRenderer {
        TextInlineRenderer(baseURL: baseURL, textStyles: styles, images: images, softBreakMode: softBreakMode, attributes: attributes)
    }

    private func styledAttributes(style: FontProperties.Style = .normal, weight: Font.Weight = .regular) -> AttributeContainer {
        var result = attributes
        result.fontProperties = FontProperties(style: style, weight: weight, size: 17)
        return result
    }

    private func legacyText(_ fragments: [(String, AttributeContainer)]) -> Text {
        fragments.reduce(Text("")) { result, fragment in
            result + Text(AttributedString(fragment.0, attributes: fragment.1).resolvingFonts())
        }
    }

    private func assertSamePixels(_ actual: Text, _ expected: Text, file: StaticString = #filePath, line: UInt = #line) throws {
        func render(_ text: Text) throws -> CGImage {
            let renderer = ImageRenderer(content: text
                .frame(width: 360, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.colorScheme, .light))
            renderer.scale = 1
            return try XCTUnwrap(renderer.cgImage, file: file, line: line)
        }
        let actualImage = try render(actual)
        let expectedImage = try render(expected)
        XCTAssertEqual(actualImage.width, expectedImage.width, file: file, line: line)
        XCTAssertEqual(actualImage.height, expectedImage.height, file: file, line: line)
        let actualData = try pixels(actualImage)
        let expectedData = try pixels(expectedImage)
        XCTAssertEqual(actualData, expectedData, file: file, line: line)
    }

    private func pixels(_ image: CGImage) throws -> Data {
        // Compare visible pixels, excluding ImageRenderer's backing-buffer padding.
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }
}
#endif
