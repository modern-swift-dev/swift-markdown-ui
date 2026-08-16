@testable import MarkdownUI
import SwiftUI
import XCTest

final class RendererHardeningTests: XCTestCase {
    func testInlineImageDiscoveryRecursesThroughStylesAndKeepsDistinctAltText() {
        let inlines: [InlineNode] = [
            .emphasis(
                children: [
                    .strong(
                        children: [
                            .image(source: "shared.png", children: [.text("first")])
                        ]
                    )
                ]
            ),
            .link(
                destination: "https://example.com",
                children: [
                    .strikethrough(
                        children: [
                            .image(source: "shared.png", children: [.text("second")])
                        ]
                    )
                ]
            )
        ]

        XCTAssertEqual(
            Set(inlines.inlineImageData()),
            [
                RawImageData(source: "shared.png", alt: "first"),
                RawImageData(source: "shared.png", alt: "second")
            ]
        )
    }

    @MainActor func testInlineImageLoadingIsolatesFailures() async {
        let provider = PartialInlineImageProvider()
        let inlines: [InlineNode] = [
            .strong(
                children: [
                    .image(source: "success.png", children: [.text("success")])
                ]
            ),
            .emphasis(
                children: [
                    .image(source: "failure.png", children: [.text("failure")])
                ]
            ),
            .image(source: "http://[", children: [.text("invalid")])
        ]

        let images = await InlineText.loadInlineImages(
            in: inlines,
            baseURL: URL(string: "https://example.com/assets/"),
            imageProvider: provider
        )

        XCTAssertEqual(
            Set(images.keys),
            [RawImageData(source: "success.png", alt: "success")]
        )
        let requests = await provider.requests
        XCTAssertEqual(requests, ["failure.png", "success.png"])
    }

    func testColorSchemeFilteringOnlyRemovesImagesForTheOtherMode() {
        let invalid = InlineNode.image(source: "http://[", children: [.text("invalid")])
        let unrelated = InlineNode.image(
            source: "https://example.com/image.png#section",
            children: [.text("unrelated")]
        )
        let light = InlineNode.image(
            source: "https://example.com/light.png#gh-light-mode-only",
            children: [.text("light")]
        )
        let dark = InlineNode.image(
            source: "https://example.com/dark.png#gh-dark-mode-only",
            children: [.text("dark")]
        )

        let result = [BlockNode.paragraph(content: [invalid, unrelated, light, dark])]
            .filterImagesMatching(colorScheme: .light)

        XCTAssertEqual(result, [.paragraph(content: [invalid, unrelated, light])])
    }
}

private actor PartialInlineImageProvider: InlineImageProvider {
    private(set) var requests: Set<String> = []

    func image(with url: URL, label: String) async throws -> Image {
        self.requests.insert(url.lastPathComponent)
        guard url.lastPathComponent != "failure.png" else {
            throw URLError(.cannotLoadFromNetwork)
        }
        return Image(systemName: "photo")
    }
}
