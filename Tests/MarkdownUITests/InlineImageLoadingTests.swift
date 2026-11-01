import ImageIO
@testable import MarkdownUI
import SwiftUI
import XCTest

@MainActor final class InlineImageLoadingTests: XCTestCase {
    func testLimitsCustomProviderConcurrencyAndPreservesOccurrenceLabels() async throws {
        let provider = SuspendedInlineProvider()
        let inlines = (0 ..< 12).map {
            InlineNode.image(source: "https://example.com/shared.png", children: [.text("label \($0)")])
        }
        let loading = Task { await InlineText.loadInlineImages(in: inlines, baseURL: nil, imageProvider: provider) }
        try await waitForFourRequests(provider)
        let beforeRelease = await provider.labels.count
        XCTAssertEqual(beforeRelease, 4)
        await provider.release()
        let images = await loading.value
        let labels = await provider.labels
        let maximumActive = await provider.maximumActive
        XCTAssertEqual(Set(labels), Set((0 ..< 12).map { "label \($0)" }))
        XCTAssertEqual(images.count, 12)
        XCTAssertLessThanOrEqual(maximumActive, 4)
    }

    func testCancellationStopsSubmittingRemainingCustomRequests() async throws {
        let provider = SuspendedInlineProvider()
        let inlines = (0 ..< 12).map {
            InlineNode.image(source: "https://example.com/\($0).png", children: [])
        }
        let loading = Task { await InlineText.loadInlineImages(in: inlines, baseURL: nil, imageProvider: provider) }
        try await waitForFourRequests(provider)
        loading.cancel()
        let images = await loading.value
        let count = await provider.labels.count
        XCTAssertEqual(count, 4)
        XCTAssertTrue(images.isEmpty)
    }

    func testDefaultProviderLoadsFileAndDataURLsAndFailsForMissingFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try encodedPNG()
        try png.write(to: directory.appendingPathComponent("logo.png"))
        let file = InlineNode.image(source: "logo.png", children: [.text("file")])
        let absoluteFile = InlineNode.image(
            source: directory.appendingPathComponent("logo.png").absoluteString, children: [.text("absolute")]
        )
        let data = InlineNode.image(source: "data:image/png;base64,\(png.base64EncodedString())", children: [.text("data")])
        let missing = InlineNode.image(source: "missing.png", children: [.text("missing")])

        let images = await InlineText.loadInlineImages(
            in: [file, absoluteFile, data, missing], baseURL: directory, imageProvider: DefaultInlineImageProvider()
        )
        XCTAssertEqual(Set(images.keys.map(\.alt)), ["file", "absolute", "data"], "A missing file falls back to its alt text")
    }

    private func encodedPNG() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func waitForFourRequests(_ provider: SuspendedInlineProvider) async throws {
        for _ in 0 ..< 100 {
            if await provider.labels.count == 4 {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected four active requests")
    }
}

private actor SuspendedInlineProvider: InlineImageProvider {
    private(set) var labels: [String] = []
    private(set) var maximumActive = 0
    private var active = 0
    private var suspended = true

    func release() {
        suspended = false
    }

    func image(with url: URL, label: String) async throws -> Image {
        labels.append(label)
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        while suspended {
            try await Task.sleep(for: .milliseconds(5))
        }
        try Task.checkCancellation()
        return Image(systemName: "photo")
    }
}
