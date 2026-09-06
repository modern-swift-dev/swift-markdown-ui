#if os(macOS)
    import AppKit
    import ImageIO
    @testable import MarkdownUI
    import SwiftUI
    import XCTest

    @MainActor final class DefaultImageProviderTests: XCTestCase {
        func testBlockOccurrencesShareBackingWithInlineLoaderRequests() async throws {
            let probe = try BlockImageProbe()
            let loader = InlineImageLoader(load: { try await probe.load($0) })
            let url = try XCTUnwrap(URL(string: "https://example.com/shared"))
            let host = NSHostingView(rootView: VStack(spacing: 0) {
                DefaultImageView(url: url, loader: loader)
                DefaultImageView(url: URL(string: "shared", relativeTo: url.deletingLastPathComponent()), loader: loader)
            })
            let window = makeWindow(host)
            defer { window.contentView = nil }
            // The default inline provider requests this same absolute URL/resolution key.
            let inlineBacking = try await loader.image(for: .init(url: url, resolution: .original))
            try await wait { host.fittingSize == CGSize(width: 80, height: 80) }
            let requests = await probe.requests
            XCTAssertEqual(requests.count, 1)
            let cachedBacking = try await loader.image(for: .init(url: url, resolution: .original))
            XCTAssertTrue(inlineBacking === cachedBacking)
        }

        func testSourceAndResolutionChangesCancelPreviousLoadsAndUpdateIntrinsicSize() async throws {
            let probe = try BlockImageProbe()
            let loader = InlineImageLoader(load: { try await probe.load($0) })
            let slow = try XCTUnwrap(URL(string: "https://example.com/slow"))
            let image = try XCTUnwrap(URL(string: "https://example.com/image"))
            let host = NSHostingView(rootView: DefaultImageView(url: slow, loader: loader))
            let window = makeWindow(host)
            defer { window.contentView = nil }
            try await wait { await probe.requests.count == 1 }
            XCTAssertEqual(host.fittingSize, .zero)

            host.rootView = DefaultImageView(url: image, loader: loader)
            try await wait { await probe.cancellations == 1 }
            try await wait { host.fittingSize == CGSize(width: 80, height: 40) }

            host.rootView = DefaultImageView(url: image, resolution: .maximumPixelDimension(20), loader: loader)
            try await wait { host.fittingSize == CGSize(width: 20, height: 10) }
            let requests = await probe.requests
            XCTAssertEqual(requests.map(\.resolution), [.original, .original, .maximumPixelDimension(20)])

            host.rootView = DefaultImageView(url: slow, loader: loader)
            try await wait { await probe.requests.count == 4 }
            host.rootView = DefaultImageView(url: nil, loader: loader)
            try await wait { await probe.cancellations == 2 }
            XCTAssertGreaterThan(host.fittingSize.width, 0, "A missing URL renders the failure placeholder")
        }

        func testFailurePlaceholderAndResizeToFitRemainAvailable() async throws {
            let loader = InlineImageLoader(load: { _ in throw URLError(.cannotLoadFromNetwork) })
            let url = try XCTUnwrap(URL(string: "https://example.com/failure"))
            let host = NSHostingView(rootView: DefaultImageView(url: url, loader: loader))
            let window = makeWindow(host)
            defer { window.contentView = nil }
            try await wait { host.fittingSize.width > 0 }
            let missing = NSHostingView(rootView: DefaultImageView(url: nil, loader: loader))
            XCTAssertEqual(host.fittingSize, missing.fittingSize)

            let probe = try BlockImageProbe()
            let imageLoader = InlineImageLoader(load: { try await probe.load($0) })
            let resized = NSHostingView(rootView: DefaultImageView(url: url, loader: imageLoader).frame(width: 40))
            window.contentView = resized
            try await wait { resized.fittingSize == CGSize(width: 40, height: 20) }
        }

        private func makeWindow(_ view: NSView) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            return window
        }

        private func wait(_ condition: () async -> Bool) async throws {
            for _ in 0 ..< 200 {
                if await condition() {
                    return
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("Timed out waiting for image view")
        }
    }

    private actor BlockImageProbe {
        private(set) var requests: [InlineImageLoader.Key] = []
        private(set) var cancellations = 0
        private let data: Data

        init() throws {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let image = try XCTUnwrap(context.makeImage())
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            self.data = data as Data
        }

        func load(_ key: InlineImageLoader.Key) async throws -> InlineImageLoader.Resource {
            self.requests.append(key)
            if key.url.lastPathComponent == "slow" {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    self.cancellations += 1
                    throw error
                }
            }
            return .init(
                image: try InlineImageLoader.decode(self.data, resolution: key.resolution),
                expiration: Date().addingTimeInterval(60)
            )
        }
    }
#endif
