#if os(macOS)
    import AppKit
    @testable import MarkdownUI
    import XCTest

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
    }
#endif
