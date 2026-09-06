#if os(macOS)
    import AppKit
    @testable import MarkdownUI
    import SwiftUI
    import XCTest

    @MainActor final class ResizeToFitCacheTests: XCTestCase {
        func testCachedIntrinsicSizeRespondsToImageAndContainerChanges() {
            let host = NSHostingView(rootView: image(size: CGSize(width: 400, height: 200), width: 100))
            XCTAssertEqual(host.fittingSize, CGSize(width: 100, height: 50))
            host.rootView = image(size: CGSize(width: 400, height: 200), width: 200)
            XCTAssertEqual(host.fittingSize, CGSize(width: 200, height: 100))
            host.rootView = image(size: CGSize(width: 400, height: 400), width: 200)
            XCTAssertEqual(host.fittingSize, CGSize(width: 200, height: 200))
            host.rootView = image(size: CGSize(width: 50, height: 25), width: 200)
            XCTAssertEqual(host.fittingSize, CGSize(width: 200, height: 25))
        }

        private func image(size: CGSize, width: CGFloat) -> some View {
            ResizeToFit { Image(nsImage: NSImage(size: size)).resizable() }.frame(width: width)
        }
    }
#endif
