@testable import MarkdownUI
import SwiftUI
import XCTest

@MainActor final class AssetImageProviderRenderingTests: XCTestCase {
    private final class Names: @unchecked Sendable {
        var urls: [URL] = []
    }

    func testImageIsLoadedFromTheBundleByTheLastPathComponentOfTheURL() throws {
        let provider = AssetImageProvider(bundle: .module)
        let url = try XCTUnwrap(URL(string: "https://example.com/photos/237-125x75"))
        let image = try RenderedImage.render(provider.makeImage(url: url), width: 1000)
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertEqual(Double(image.width) / Double(image.height), 125.0 / 75.0, accuracy: 0.05)
    }

    func testNameClosureReceivesTheURLAndChoosesTheAsset() throws {
        let names = Names()
        let provider = AssetImageProvider(
            name: { url in
                names.urls.append(url)
                return url.host() == "wide" ? "237-500x300" : "237-100x150"
            },
            bundle: .module
        )
        let wideURL = try XCTUnwrap(URL(string: "https://wide/image.png"))
        let tallURL = try XCTUnwrap(URL(string: "https://tall/image.png"))
        let wide = try RenderedImage.render(provider.makeImage(url: wideURL), width: 1000)
        let tall = try RenderedImage.render(provider.makeImage(url: tallURL), width: 1000)
        XCTAssertTrue(names.urls.contains(wideURL))
        XCTAssertTrue(names.urls.contains(tallURL))
        XCTAssertGreaterThan(wide.width, wide.height, "The 500x300 asset is landscape")
        XCTAssertGreaterThan(tall.height, tall.width, "The 100x150 asset is portrait")
    }

    func testImagesShrinkToFitTheProposedWidthKeepingTheirAspectRatio() throws {
        let provider = AssetImageProvider(name: { _ in "237-500x300" }, bundle: .module)
        let url = try XCTUnwrap(URL(string: "https://example.com/any"))
        let natural = try RenderedImage.render(provider.makeImage(url: url), width: 5000)
        let shrunk = try RenderedImage.render(provider.makeImage(url: url), width: 50)
        XCTAssertEqual(shrunk.width, 50)
        XCTAssertEqual(Double(shrunk.height), Double(natural.height) * 50 / Double(natural.width), accuracy: 1)
    }

    func testMissingURLOrMissingAssetRendersNothing() throws {
        let provider = AssetImageProvider(bundle: .module)
        XCTAssertTrue(RenderedImage.rendersNothing(provider.makeImage(url: nil)))
        let missing = try XCTUnwrap(URL(string: "https://example.com/not-an-asset"))
        XCTAssertTrue(RenderedImage.rendersNothing(provider.makeImage(url: missing)))
    }

    func testAssetProviderDefaultsToTheMainBundle() throws {
        let provider: AssetImageProvider = .asset
        let missing = try XCTUnwrap(URL(string: "https://example.com/237-125x75"))
        XCTAssertTrue(
            RenderedImage.rendersNothing(provider.makeImage(url: missing)),
            "The test assets live in the test bundle, not the main bundle"
        )
    }

    func testAssetProviderIsUsedForMarkdownImages() throws {
        let view = MarkdownView("![alt](237-125x75)")
            .markdownImageProvider(AssetImageProvider(bundle: .module))
        let image = try RenderedImage.render(view, width: 400)
        XCTAssertGreaterThan(image.height, 0)
        let missing = MarkdownView("![alt](not-an-asset)")
            .markdownImageProvider(AssetImageProvider(bundle: .module))
        XCTAssertTrue(RenderedImage.rendersNothing(missing.frame(width: 400)))
    }
}
