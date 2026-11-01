@testable import MarkdownUI
import SwiftUI
import XCTest

final class AssetInlineImageProviderTests: XCTestCase {
    func testMissingAssetThrowsSoItsAltTextIsShown() async throws {
        let provider = AssetInlineImageProvider(bundle: .module)
        let missing = try XCTUnwrap(URL(string: "https://example.com/missing-image"))
        do {
            _ = try await provider.image(with: missing, label: "missing")
            XCTFail("Expected a missing asset to throw")
        } catch {}

        let images = await InlineText.loadInlineImages(
            in: [
                .image(source: "https://example.com/237-125x75", children: [.text("existing")]),
                .image(source: "https://example.com/missing-image", children: [.text("missing")])
            ],
            baseURL: nil,
            imageProvider: provider
        )
        XCTAssertEqual(images.keys.map(\.alt), ["existing"], "Only loaded images replace their alt text")
    }

    func testCustomNameMappingThrowsForMissingAsset() async throws {
        let provider = AssetInlineImageProvider(name: { $0.host() ?? "" }, bundle: .module)
        _ = try await provider.image(with: XCTUnwrap(URL(string: "asset://237-125x75/x")), label: "existing")
        do {
            _ = try await provider.image(with: XCTUnwrap(URL(string: "asset://missing-image/x")), label: "missing")
            XCTFail("Expected a missing asset to throw")
        } catch {}
    }
}

#if os(macOS)
    import AppKit

    @MainActor final class AssetImageProviderTests: XCTestCase {
        func testBundleImagesAreCachedByBundleAndName() throws {
            let image = try XCTUnwrap(AssetImageProvider.image(named: "237-125x75", in: .module))
            XCTAssertTrue(AssetImageProvider.image(named: "237-125x75", in: .module) === image)
            XCTAssertEqual(image.size, Bundle.module.image(forResource: "237-125x75")?.size)
            let other = try XCTUnwrap(AssetImageProvider.image(named: "237-100x150", in: .module))
            XCTAssertFalse(other === image)
            XCTAssertNil(AssetImageProvider.image(named: "missing-image", in: .module))
            XCTAssertNil(AssetImageProvider.image(named: "missing-image", in: .module))
        }

        func testMissingAssetRendersNothing() {
            let provider = AssetImageProvider(bundle: .module)
            let existing = NSHostingView(rootView: provider.makeImage(url: URL(string: "https://example.com/237-125x75")))
            XCTAssertEqual(existing.fittingSize, CGSize(width: 125, height: 75))
            let missing = NSHostingView(rootView: provider.makeImage(url: URL(string: "https://example.com/missing-image")))
            XCTAssertEqual(missing.fittingSize, .zero)
        }
    }
#endif
