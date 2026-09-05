import Foundation
@testable import MarkdownUIEditor
import XCTest

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor final class MarkdownEditorImageLoadingTests: XCTestCase {
    func testProviderCoalescesRequestsAndReusesDecodedImageAcrossViews() async throws {
        let probe = NativeImageProbe()
        let provider = MarkdownURLSessionImageProvider(loader: MarkdownEditorImageLoader(load: probe.load))
        let url = try imageURL()
        let first = MarkdownImageViewLoader(provider: provider, url: url)
        let second = MarkdownImageViewLoader(provider: provider, url: url)
        var firstImage: MarkdownEditorPlatformImage?
        var secondImage: MarkdownEditorPlatformImage?
        first.start { firstImage = $0 }
        second.start { secondImage = $0 }
        try await wait { probe.started == 1 }
        probe.suspended = false
        try await wait { firstImage != nil && secondImage != nil }
        XCTAssertTrue(firstImage === secondImage)
        let replacement = MarkdownImageViewLoader(provider: provider, url: url)
        var replacementImage: MarkdownEditorPlatformImage?
        replacement.start { replacementImage = $0 }
        try await wait { replacementImage != nil }
        XCTAssertTrue(firstImage === replacementImage)
        XCTAssertEqual(probe.started, 1)
    }

    func testCancellingOneViewKeepsSharedRequestAndCancellingLastStopsIt() async throws {
        let probe = NativeImageProbe()
        let provider = MarkdownURLSessionImageProvider(loader: MarkdownEditorImageLoader(load: probe.load))
        let url = try imageURL()
        let first = MarkdownImageViewLoader(provider: provider, url: url)
        let second = MarkdownImageViewLoader(provider: provider, url: url)
        first.start { _ in XCTFail("Cancelled view must not receive image") }
        second.start { _ in XCTFail("Cancelled view must not receive image") }
        try await wait { probe.started == 1 }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(probe.cancellations, 0)
        second.cancel()
        try await wait { probe.cancellations == 1 }
        XCTAssertEqual(probe.started, 1)
    }

    func testBoundsActiveRequestsAndSkipsCancelledQueue() async throws {
        let probe = NativeImageProbe()
        let loader = MarkdownEditorImageLoader(load: probe.load)
        let baseURL = try imageURL()
        let requests = (0 ..< 12).map { index in
            Task { try await loader.image(for: baseURL.appendingPathComponent(String(index))) }
        }
        try await wait { probe.started == 4 }
        for request in requests {
            request.cancel()
        }
        for request in requests {
            _ = try? await request.value
        }
        try await wait { probe.cancellations == 4 }
        XCTAssertEqual(probe.started, 4)
    }

    func testViewOwnerDeinitCancelsOutstandingRequest() async throws {
        let provider = SuspendedNativeProvider()
        var loader: MarkdownImageViewLoader? = MarkdownImageViewLoader(provider: provider, url: try imageURL())
        loader?.start { _ in XCTFail("Released owner must not receive an image") }
        try await wait { provider.started == 1 }
        loader = nil
        try await wait { provider.cancellations == 1 }
    }

    func testCancelledUncooperativeProviderCannotApplyLateResult() async throws {
        let provider = UncooperativeNativeProvider()
        let loader = MarkdownImageViewLoader(provider: provider, url: try imageURL())
        var received = false
        loader.start { _ in received = true }
        try await wait { provider.continuation != nil }
        loader.cancel()
        provider.finish()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(received)
    }

    func testCompletedViewImageSurvivesDetachAndReattachWithoutReload() async throws {
        let probe = NativeImageProbe()
        probe.suspended = false
        let provider = MarkdownURLSessionImageProvider(loader: MarkdownEditorImageLoader(maximumCacheCost: 0, load: probe.load))
        let loader = MarkdownImageViewLoader(provider: provider, url: try imageURL())
        var received = 0
        loader.start { _ in received += 1 }
        try await wait { received == 1 }
        loader.cancel()
        loader.start { _ in received += 1 }
        XCTAssertEqual(received, 2)
        XCTAssertEqual(probe.started, 1)
    }

    func testCacheSkipsOversizedExpiredAndNoStoreImages() async throws {
        let probe = NativeImageProbe()
        probe.suspended = false
        let url = try imageURL()
        let small = MarkdownEditorImageLoader(maximumCacheCost: 1, load: probe.load)
        _ = try await small.image(for: url)
        _ = try await small.image(for: url)
        XCTAssertEqual(probe.started, 2)
        let noStore = MarkdownEditorImageLoader { url in
            let resource = try await probe.load(url)
            return .init(image: resource.image, cost: resource.cost, expiration: nil)
        }
        _ = try await noStore.image(for: url)
        _ = try await noStore.image(for: url)
        XCTAssertEqual(probe.started, 4)
        let expired = MarkdownEditorImageLoader { url in
            let resource = try await probe.load(url)
            return .init(image: resource.image, cost: resource.cost, expiration: .distantPast)
        }
        _ = try await expired.image(for: url)
        _ = try await expired.image(for: url)
        XCTAssertEqual(probe.started, 6)
    }

    func testHTTPFreshnessDoesNotExtendAlreadyAgedResponse() throws {
        let url = try imageURL()
        let now = Date(timeIntervalSince1970: 1_783_252_800)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        let oldDate = formatter.string(from: now.addingTimeInterval(-90))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "Cache-Control": "max-age=120", "Date": oldDate
        ]))
        XCTAssertEqual(MarkdownEditorImageLoader.cacheExpiration(for: response, now: now), now.addingTimeInterval(30))
        let noCache = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "Cache-Control": "max-age=120, no-cache=\"Set-Cookie\""
        ]))
        XCTAssertNil(MarkdownEditorImageLoader.cacheExpiration(for: noCache, now: now))
    }

    #if canImport(AppKit)
    func testNativeViewDetachCancelsAndReattachRestarts() async throws {
        let provider = SuspendedNativeProvider()
        let attachment = MarkdownImageAttachment(metadata: .init(source: "https://example.com/image.png", altText: "image"), imageProvider: provider)
        let storage = NSTextContentStorage()
        let viewProvider = try XCTUnwrap(attachment.viewProvider(for: nil, location: storage.documentRange.location, textContainer: nil))
        let imageView = try XCTUnwrap(viewProvider.view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: window.frame)
        window.contentView = container
        defer { window.contentView = nil }
        container.addSubview(imageView)
        try await wait { provider.started == 1 }
        imageView.removeFromSuperview()
        try await wait { provider.cancellations == 1 }
        container.addSubview(imageView)
        try await wait { provider.started == 2 }
        imageView.removeFromSuperview()
        try await wait { provider.cancellations == 2 }
    }
    #endif

    private func imageURL() throws -> URL {
        try XCTUnwrap(URL(string: "https://example.com/image.png"))
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for image lifecycle")
    }
}

@MainActor private final class NativeImageProbe {
    var started = 0
    var cancellations = 0
    var suspended = true

    func load(_ url: URL) async throws -> MarkdownEditorImageLoader.Resource {
        started += 1
        do {
            while suspended {
                try await Task.sleep(for: .milliseconds(5))
            }
            try Task.checkCancellation()
        } catch {
            cancellations += 1
            throw error
        }
        return .init(image: nativeImage(), cost: 1024, expiration: Date().addingTimeInterval(60))
    }
}

@MainActor private final class SuspendedNativeProvider: MarkdownEditorImageProvider {
    var started = 0
    var cancellations = 0
    func image(for url: URL) async throws -> MarkdownEditorPlatformImage {
        started += 1
        do { try await Task.sleep(for: .seconds(30)) } catch { cancellations += 1; throw error }
        return nativeImage()
    }
}

@MainActor private final class UncooperativeNativeProvider: MarkdownEditorImageProvider {
    var continuation: CheckedContinuation<MarkdownEditorPlatformImage, Never>?
    func image(for url: URL) async throws -> MarkdownEditorPlatformImage {
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume(returning: nativeImage()); continuation = nil
    }
}

@MainActor private func nativeImage() -> MarkdownEditorPlatformImage {
    #if canImport(AppKit)
    NSImage(size: NSSize(width: 4, height: 4))
    #else
    UIImage()
    #endif
}
