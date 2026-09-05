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
