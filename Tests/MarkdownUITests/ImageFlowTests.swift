@testable import MarkdownUI
import SwiftUI
import XCTest

@MainActor final class ImageFlowTests: XCTestCase {
    /// Spacing between images is a quarter of the font size.
    private static let fontSize: CGFloat = 20
    private static let spacing = 5

    private func image(_ size: String) -> InlineNode {
        .image(source: size, children: [.text("alt")])
    }

    /// Renders a paragraph made only of the given Markdown images.
    private func render(_ markdown: String, width: CGFloat) throws -> CGImage {
        try RenderedImage.render(
            MarkdownView(markdown)
                .markdownImageProvider(SizedSwatchImageProvider())
                .markdownTextStyle(\.text) { FontSize(Self.fontSize) },
            width: width
        )
    }

    func testImagesSeparatedBySpacesAreInlineTextNotAnImageFlow() {
        XCTAssertNil(ImageFlow([image("10x10"), .text(" "), image("10x10")]))
    }

    func testOnlyImagesLinksToImagesAndBreaksFormAnImageFlow() {
        XCTAssertNotNil(ImageFlow([image("10x10"), .softBreak, .text(""), image("10x10")]))
        XCTAssertNotNil(ImageFlow([.link(destination: "https://example.com", children: [image("10x10")])]))
        XCTAssertNotNil(ImageFlow([image("10x10"), .lineBreak, image("10x10")]))
        XCTAssertNil(ImageFlow([image("10x10"), .text("caption")]))
        XCTAssertNil(ImageFlow([image("10x10"), .strong(children: [.text("bold")])]))
        XCTAssertNil(ImageFlow([.link(destination: "https://example.com", children: [.text("not an image")])]))
        XCTAssertNil(ImageFlow([.link(destination: "https://example.com", children: [image("10x10"), image("10x10")])]))
    }

    func testImagesOfDifferentSizesShareARowSeparatedByAQuarterOfTheFontSize() throws {
        let image = try render("![a](30x10)\n![b](20x25)\n![c](40x15)", width: 400)
        XCTAssertEqual(RenderedImage.size(of: image).height, 25)
        // Images align to the bottom edge of the row and are 5pt apart.
        let first = try RenderedImage.column(10, in: image)
        XCTAssertEqual(first.filter { $0 == .pureRed }.count, 10)
        XCTAssertEqual(first.last, .pureRed)
        XCTAssertEqual(first[14], .clear)
        let second = try RenderedImage.column(30 + Self.spacing + 10, in: image)
        XCTAssertEqual(second.filter { $0 == .pureRed }.count, 25)
        let third = try RenderedImage.column(30 + Self.spacing + 20 + Self.spacing + 20, in: image)
        XCTAssertEqual(third.filter { $0 == .pureRed }.count, 15)
        let gap = try RenderedImage.column(30 + Self.spacing / 2, in: image)
        XCTAssertEqual(gap.filter { $0 == .pureRed }.count, 0, "The spacing between images stays empty")
    }

    func testImagesWrapWhenTheRowIsFullAndRowsAreSeparatedBySpacing() throws {
        // Two 30pt images take 65pt including a trailing spacing, so a third one wraps at 70pt.
        let image = try render("![a](30x10)\n![b](30x20)\n![c](30x10)", width: 70)
        XCTAssertEqual(RenderedImage.size(of: image).height, CGFloat(20 + Self.spacing + 10))
        let firstColumn = try RenderedImage.column(10, in: image)
        XCTAssertEqual(firstColumn.filter { $0 == .pureRed }.count, 10 + 10, "Both rows have an image at x=10")
        XCTAssertEqual(firstColumn.last, .pureRed)
        XCTAssertEqual(firstColumn[20 + Self.spacing / 2], .clear, "Spacing between the rows")
    }

    func testImagesWiderThanTheAvailableWidthStackOnSeparateRows() throws {
        let image = try render("![a](50x10)\n![b](50x10)\n![c](50x10)", width: 60)
        XCTAssertEqual(RenderedImage.size(of: image).height, CGFloat(10 * 3 + Self.spacing * 2))
    }

    func testSoftBreaksDoNotSplitRowsButLineBreaksDo() throws {
        let softBroken = try render("![a](20x10)\n![b](20x10)", width: 400)
        XCTAssertEqual(RenderedImage.size(of: softBroken).height, 10)

        let hardBroken = try render("![a](20x10)\\\n![b](20x10)", width: 400)
        XCTAssertEqual(
            RenderedImage.size(of: hardBroken).height, CGFloat(10 + Self.spacing + 10),
            "A hard break puts each image on its own row separated by a single spacing"
        )
        let column = try RenderedImage.column(10, in: hardBroken)
        XCTAssertEqual(column.filter { $0 == .pureRed }.count, 20)
    }

    func testLinkedImagesAreIncludedInTheFlow() throws {
        let image = try render("![a](15x10)\n[![b](25x10)](https://example.com)", width: 400)
        XCTAssertEqual(RenderedImage.size(of: image).height, 10)
        let linked = try RenderedImage.column(15 + Self.spacing + 10, in: image)
        XCTAssertEqual(linked.filter { $0 == .pureRed }.count, 10)
    }
}

private struct SizedSwatchImageProvider: ImageProvider {
    /// Images are named `<width>x<height>` and render as red rectangles of that size.
    func makeImage(url: URL?) -> some View {
        let parts = url?.lastPathComponent.split(separator: "x").compactMap { Double($0) } ?? []
        return Color.pureRed.frame(width: parts.first ?? 1, height: parts.last ?? 1)
    }
}
