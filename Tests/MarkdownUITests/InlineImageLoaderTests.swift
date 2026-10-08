import Foundation
import ImageIO
@testable import MarkdownUI
import os
import XCTest

@MainActor final class InlineImageLoaderTests: XCTestCase {
    func testCoalescesRequestsAndReusesDecodedBacking() async throws {
        let probe = LoaderProbe()
        let loader = InlineImageLoader(load: { try await probe.load($0) })
        let key = try key("shared")
        let first = Task { try await loader.image(for: key).image }
        let second = Task { try await loader.image(for: key).image }
        try await wait { await probe.started == 1 }
        try await Task.sleep(for: .milliseconds(30))
        await probe.release()
        let firstImage = try await first.value
        let secondImage = try await second.value
        let cached = try await loader.image(for: key).image
        XCTAssertTrue(firstImage === secondImage)
        XCTAssertTrue(firstImage === cached)
        let started = await probe.started
        XCTAssertEqual(started, 1)
    }

    func testLimitsActiveLoadsAndDoesNotStartCancelledQueuedRequest() async throws {
        let probe = LoaderProbe()
        let loader = InlineImageLoader(maximumConcurrentLoads: 1, load: { try await probe.load($0) })
        let first = Task { try await loader.image(for: key("first")) }
        try await wait { await probe.started == 1 }
        let queued = Task { try await loader.image(for: key("queued")) }
        try await Task.sleep(for: .milliseconds(30))
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { throw error }
        await probe.release()
        _ = try await first.value
        let started = await probe.started
        XCTAssertEqual(started, 1)
    }

    func testLargeQueueCompactsCancelledJobsAndDrainsSurvivors() async throws {
        let probe = LoaderProbe()
        let loader = InlineImageLoader(maximumConcurrentLoads: 1, maximumCacheCost: 0, load: { try await probe.load($0) })
        let active = Task { try await loader.image(for: key("active")) }
        try await wait { await probe.started == 1 }
        let queued = (0 ..< 256).map { index in
            Task { try await loader.image(for: key("queued-\(index)")) }
        }
        try await wait { await loader.pendingLoadCount == queued.count }
        for task in queued.prefix(192) {
            task.cancel()
        }
        for task in queued.prefix(192) {
            do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { throw error }
        }
        let remaining = await loader.pendingLoadCount
        let storage = await loader.pendingStorageCount
        XCTAssertEqual(remaining, 64)
        XCTAssertLessThanOrEqual(storage, 128, "Cancelled entries should compact while the active slot is occupied")
        await probe.release()
        _ = try await active.value
        for task in queued.suffix(64) {
            _ = try await task.value
        }
        let names = await probe.startedNames
        XCTAssertEqual(Set(names), Set(["active"] + (192 ..< 256).map { "queued-\($0)" }))
        let drainedStorage = await loader.pendingStorageCount
        XCTAssertEqual(drainedStorage, 0)
    }

    func testCancellingEntireLargeQueueReleasesStorageBeforeActiveLoadFinishes() async throws {
        let probe = LoaderProbe()
        let loader = InlineImageLoader(maximumConcurrentLoads: 1, maximumCacheCost: 0, load: { try await probe.load($0) })
        let active = Task { try await loader.image(for: key("active")) }
        try await wait { await probe.started == 1 }
        let queued = (0 ..< 256).map { index in
            Task { try await loader.image(for: key("cancelled-\(index)")) }
        }
        try await wait { await loader.pendingLoadCount == queued.count }
        for task in queued {
            task.cancel()
        }
        for task in queued {
            do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { throw error }
        }
        let storage = await loader.pendingStorageCount
        let remaining = await loader.pendingLoadCount
        XCTAssertEqual(storage, 0)
        XCTAssertEqual(remaining, 0)
        let replacement = Task { try await loader.image(for: key("replacement")) }
        try await wait { await loader.pendingLoadCount == 1 }
        await probe.release()
        _ = try await active.value
        _ = try await replacement.value
        let names = await probe.startedNames
        XCTAssertEqual(names, ["active", "replacement"])
    }

    func testCancellingOneWaiterKeepsSharedLoadAlive() async throws {
        let probe = LoaderProbe()
        let loader = InlineImageLoader(load: { try await probe.load($0) })
        let key = try key("shared")
        let first = Task { try await loader.image(for: key) }
        let second = Task { try await loader.image(for: key) }
        try await wait { await probe.started == 1 }
        try await Task.sleep(for: .milliseconds(30))
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { throw error }
        await probe.release()
        _ = try await second.value
        let cancellations = await probe.cancellations
        XCTAssertEqual(cancellations, 0)
    }

    func testCancellingLastWaiterCancelsDownloadAndAllowsRetry() async throws {
        let probe = LoaderProbe()
        let loader = InlineImageLoader(maximumConcurrentLoads: 1, load: { try await probe.load($0) })
        let key = try key("shared")
        let first = Task { try await loader.image(for: key) }
        try await wait { await probe.started == 1 }
        first.cancel()
        _ = try? await first.value
        try await wait { await probe.cancellations == 1 }
        let retry = Task { try await loader.image(for: key) }
        try await wait { await probe.started == 2 }
        await probe.release()
        _ = try await retry.value
    }

    func testEvictsDecodedImagesByCostAndDoesNotCacheUncacheableResources() async throws {
        let probe = LoaderProbe(suspended: false)
        let image = try makeImage()
        let loader = InlineImageLoader(maximumCacheCost: image.bytesPerRow * image.height, load: { try await probe.load($0) })
        _ = try await loader.image(for: key("first"))
        _ = try await loader.image(for: key("second"))
        _ = try await loader.image(for: key("first"))
        let started = await probe.started
        XCTAssertEqual(started, 3)
        let uncached = InlineImageLoader(load: { key in
            let result = try await probe.load(key)
            return .init(image: result.image, expiration: nil)
        })
        _ = try await uncached.image(for: key("no-store"))
        _ = try await uncached.image(for: key("no-store"))
        let total = await probe.started
        XCTAssertEqual(total, 5)
    }

    func testLargeAdmissionEvictsLeastRecentlyUsedImagesAndReleasesTheirBacking() async throws {
        let small = try makeImage()
        let smallCost = small.bytesPerRow * small.height
        let entryCount = 128
        let large = try makeImage(width: small.width, height: small.height * (entryCount - 4))
        XCTAssertEqual(large.bytesPerRow * large.height, smallCost * (entryCount - 4))
        let loader = InlineImageLoader(maximumCacheCost: smallCost * entryCount, load: { key in
            .init(
                image: key.url.lastPathComponent == "large" ? large : try makeImage(),
                expiration: Date().addingTimeInterval(60)
            )
        })
        var backings: [WeakReference<CGImage>] = []
        for index in 0 ..< entryCount {
            var image: CGImage? = try await loader.image(for: key("small-\(index)")).image
            backings.append(WeakReference(image))
            image = nil
        }
        // Touch the oldest entries so they survive alongside the newest two.
        for index in 0 ..< 2 {
            let image = try await loader.image(for: key("small-\(index)")).image
            XCTAssertTrue(image === backings[index].value)
        }
        _ = try await loader.image(for: key("large"))
        try await wait { backings[2 ..< entryCount - 2].allSatisfy { $0.value == nil } }
        for index in [0, 1, entryCount - 2, entryCount - 1] {
            XCTAssertNotNil(backings[index].value)
            let image = try await loader.image(for: key("small-\(index)")).image
            XCTAssertTrue(image === backings[index].value, "Recent images should retain their backing")
        }
        await loader.purgeCache()
        try await wait { backings.allSatisfy { $0.value == nil } }
    }

    func testIdleExpirationReleasesDecodedBackingAndPreservesFreshEntries() async throws {
        let clock = ImageExpirationClock()
        let sleeper = ImageExpirationSleeper()
        let loader = InlineImageLoader(now: { clock.now }, sleepUntil: { await sleeper.sleep(until: $0) }, load: { key in
            .init(image: try makeImage(), expiration: clock.now.addingTimeInterval(key.url.lastPathComponent == "first" ? 10 : 20))
        })
        var first: CGImage? = try await loader.image(for: key("first")).image
        let expiredBacking = WeakReference(first)
        first = nil
        var second: CGImage? = try await loader.image(for: key("second")).image
        let freshBacking = WeakReference(second)
        second = nil
        XCTAssertNotNil(expiredBacking.value)
        try await wait { await sleeper.isSleeping }
        clock.advance(by: 10)
        await sleeper.wake()
        try await wait { await sleeper.isSleeping }
        XCTAssertNil(expiredBacking.value, "Expiration must release storage without another image request")
        XCTAssertNotNil(freshBacking.value)
        clock.advance(by: 10)
        await sleeper.wake()
        try await wait { freshBacking.value == nil }
    }

    func testMemoryPressurePurgeReleasesBackingAndAllowsReload() async throws {
        let probe = LoaderProbe(suspended: false)
        let loader = InlineImageLoader(load: { try await probe.load($0) })
        let key = try key("purged")
        var image: CGImage? = try await loader.image(for: key).image
        let backing = WeakReference(image)
        image = nil
        XCTAssertNotNil(backing.value)
        // This is the same actor entry point used by the dispatch memory-pressure handler.
        await loader.purgeCache()
        try await wait { backing.value == nil }
        _ = try await loader.image(for: key)
        let started = await probe.started
        XCTAssertEqual(started, 2)
        await loader.purgeCache()
    }

    func testExpirationTaskDoesNotRetainLoader() async throws {
        let probe = LoaderProbe(suspended: false)
        var loader: InlineImageLoader? = InlineImageLoader(load: { try await probe.load($0) })
        let weakLoader = WeakReference(loader)
        _ = try await loader?.image(for: key("released"))
        loader = nil
        try await wait { weakLoader.value == nil }
    }

    func testHTTPFreshnessAndNoStore() throws {
        let now = Date()
        func expiration(_ fields: [String: String]) throws -> Date? {
            let response = try XCTUnwrap(HTTPURLResponse(
                url: key("http").url, statusCode: 200, httpVersion: nil, headerFields: fields
            ))
            return InlineImageLoader.cacheExpiration(for: response, now: now)
        }
        XCTAssertNil(try expiration([:]))
        XCTAssertNil(try expiration(["Cache-Control": "max-age=120, no-store"]))
        XCTAssertNil(try expiration(["Cache-Control": "no-cache, max-age=120"]))
        XCTAssertNil(try expiration(["Cache-Control": "max-age=10", "Age": "11"]))
        XCTAssertEqual(try expiration(["Cache-Control": "max-age=120"]), now.addingTimeInterval(60))
        XCTAssertEqual(try expiration(["Cache-Control": "max-age=30", "Age": "10"]), now.addingTimeInterval(20))
    }

    func testHTTPFreshnessSubtractsApparentAgeAndHonorsQualifiedNoCache() throws {
        let now = Date(timeIntervalSince1970: 1_783_252_800)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        let response = try XCTUnwrap(HTTPURLResponse(
            url: key("http").url, statusCode: 200, httpVersion: nil, headerFields: [
                "Cache-Control": "max-age=120", "Date": formatter.string(from: now.addingTimeInterval(-90))
            ]
        ))
        XCTAssertEqual(InlineImageLoader.cacheExpiration(for: response, now: now), now.addingTimeInterval(30))
        let noCache = try XCTUnwrap(HTTPURLResponse(
            url: key("http").url, statusCode: 200, httpVersion: nil,
            headerFields: ["Cache-Control": "max-age=120, no-cache=\"Set-Cookie\""]
        ))
        XCTAssertNil(InlineImageLoader.cacheExpiration(for: noCache, now: now))
    }

    func testConcurrentResponsesShareDateParsing() throws {
        let now = Date(timeIntervalSince1970: 1_783_252_800)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: key("http").url, statusCode: 200, httpVersion: nil, headerFields: [
                "Cache-Control": "max-age=50", "Date": "Sun, 05 Jul 2026 11:59:40 GMT"
            ]
        ))
        let mismatches = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if InlineImageLoader.cacheExpiration(for: response, now: now) != now.addingTimeInterval(30) {
                mismatches.withLock { $0 += 1 }
            }
        }
        XCTAssertEqual(mismatches.withLock { $0 }, 0)
    }

    func testDownsamplingIsOptInAndPartOfProviderIdentity() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try makeImage(width: 80, height: 40), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try InlineImageLoader.decode(data as Data, resolution: .original).image
        let thumbnail = try InlineImageLoader.decode(data as Data, resolution: .maximumPixelDimension(20)).image
        XCTAssertEqual(original.width, 80)
        XCTAssertEqual(original.height, 40)
        XCTAssertEqual(thumbnail.width, 20)
        XCTAssertEqual(thumbnail.height, 10)
        XCTAssertNotEqual(
            InlineImageProviderContext(provider: DefaultInlineImageProvider()).id,
            InlineImageProviderContext(provider: DefaultInlineImageProvider(resolution: .maximumPixelDimension(20))).id
        )
    }

    func testDownsamplingIsTheDefaultAndPreservesLayoutSize() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try makeImage(width: 80, height: 40), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        XCTAssertEqual(DefaultInlineImageProvider().resolution, .downsampled(maximumPixelDimension: 2048))
        let belowLimit = try InlineImageLoader.decode(data as Data, resolution: DefaultInlineImageProvider().resolution)
        XCTAssertEqual(belowLimit.image.width, 80)
        XCTAssertEqual(belowLimit.scale, 1)

        let downsampled = try InlineImageLoader.decode(data as Data, resolution: .downsampled(maximumPixelDimension: 20))
        XCTAssertEqual(downsampled.image.width, 20)
        XCTAssertEqual(downsampled.image.height, 10)
        XCTAssertEqual(CGFloat(downsampled.image.width) / downsampled.scale, 80)
        XCTAssertEqual(CGFloat(downsampled.image.height) / downsampled.scale, 40)

        let ids = [
            DefaultInlineImageProvider(),
            DefaultInlineImageProvider(resolution: .original),
            DefaultInlineImageProvider(resolution: .maximumPixelDimension(20)),
            DefaultInlineImageProvider(resolution: .downsampled(maximumPixelDimension: 20))
        ].map { InlineImageProviderContext(provider: $0).id }
        for (index, id) in ids.enumerated() {
            XCTAssertEqual(ids.firstIndex(of: id), index, "Each resolution needs its own identity")
        }
    }

    func testPixelBudgetReducesDecodeAndPreservesLayoutSize() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try makeImage(width: 80, height: 40), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let withinBudget = try InlineImageLoader.decode(data as Data, resolution: .original, maximumPixelCount: 3200)
        XCTAssertEqual(withinBudget.image.width, 80)
        XCTAssertEqual(withinBudget.scale, 1)

        let original = try InlineImageLoader.decode(data as Data, resolution: .original, maximumPixelCount: 800)
        XCTAssertEqual(original.image.width, 40)
        XCTAssertEqual(original.image.height, 20)
        XCTAssertEqual(CGFloat(original.image.width) / original.scale, 80)
        XCTAssertEqual(CGFloat(original.image.height) / original.scale, 40)

        // The budget also bounds explicit dimensions, keeping their requested layout size.
        let limited = try InlineImageLoader.decode(
            data as Data, resolution: .maximumPixelDimension(60), maximumPixelCount: 800
        )
        XCTAssertEqual(limited.image.width, 40)
        XCTAssertEqual(CGFloat(limited.image.width) / limited.scale, 60, accuracy: 0.001)
        XCTAssertEqual(CGFloat(limited.image.height) / limited.scale, 30, accuracy: 0.001)
    }

    func testResponseBodyRejectsDeclaredAndReceivedSizesOverLimit() async throws {
        func bytes(_ count: Int) -> AsyncStream<UInt8> {
            AsyncStream { continuation in
                for index in 0 ..< count {
                    continuation.yield(UInt8(truncatingIfNeeded: index))
                }
                continuation.finish()
            }
        }
        let body = try await InlineImageLoader.body(of: bytes(10), expectedContentLength: 10, limit: 10)
        XCTAssertEqual(body, Data((0 ..< 10).map { UInt8($0) }))
        let unknownLength = try await InlineImageLoader.body(of: bytes(10), expectedContentLength: -1, limit: 10)
        XCTAssertEqual(unknownLength.count, 10)

        for (count, expectedLength) in [(1, Int64(11)), (11, Int64(-1)), (11, Int64(5))] {
            do {
                _ = try await InlineImageLoader.body(of: bytes(count), expectedContentLength: expectedLength, limit: 10)
                XCTFail("Expected an oversized response to be rejected")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
            }
        }
    }

    func testStaleImageWithEntityTagIsRevalidatedAndReusedAfterNotModified() async throws {
        let clock = ImageExpirationClock()
        let sleeper = ImageExpirationSleeper()
        let probe = try FetchProbe()
        await probe.enqueue(.init(status: 200, headers: ["ETag": "\"a\"", "Cache-Control": "max-age=10"], body: probe.png))
        let loader = InlineImageLoader(
            now: { clock.now }, sleepUntil: { await sleeper.sleep(until: $0) }, fetch: { try await probe.fetch($0) }
        )
        let key = try key("etag")
        let first = try await loader.image(for: key).image
        _ = try await loader.image(for: key)
        var requests = await probe.requests
        XCTAssertEqual(requests.count, 1, "Fresh images are reused without a request")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "If-None-Match"))

        // The expiration timer keeps stale images that can be revalidated.
        try await wait { await sleeper.isSleeping }
        clock.advance(by: 10)
        await sleeper.wake()
        await probe.enqueue(.init(status: 304, headers: ["Cache-Control": "max-age=10"]))
        let revalidated = try await loader.image(for: key).image
        XCTAssertTrue(first === revalidated, "A 304 response reuses the decoded bitmap")
        _ = try await loader.image(for: key)
        requests = await probe.requests
        XCTAssertEqual(requests.count, 2, "A 304 response renews freshness")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"a\"")
        XCTAssertEqual(requests[1].cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testLastModifiedRevalidationReplacesImageOnSuccess() async throws {
        let probe = try FetchProbe()
        let modified = "Sun, 05 Jul 2026 11:59:40 GMT"
        await probe.enqueue(.init(status: 200, headers: ["Last-Modified": modified, "Cache-Control": "no-cache"], body: probe.png))
        let loader = InlineImageLoader(fetch: { try await probe.fetch($0) })
        let key = try key("modified")
        let first = try await loader.image(for: key).image

        let replacement = try encodedPNG(width: 8, height: 8)
        await probe.enqueue(.init(status: 200, headers: ["ETag": "\"b\""], body: replacement))
        let second = try await loader.image(for: key).image
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.width, 8)

        await probe.enqueue(.init(status: 304, headers: [:]))
        let third = try await loader.image(for: key).image
        XCTAssertTrue(second === third)
        let requests = await probe.requests
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "If-Modified-Since") }, [nil, modified, nil])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "If-None-Match") }, [nil, nil, "\"b\""])
    }

    func testNoStoreResponsesAreNeverCachedOrRevalidated() async throws {
        let probe = try FetchProbe()
        let loader = InlineImageLoader(fetch: { try await probe.fetch($0) })
        let key = try key("no-store")
        for _ in 0 ..< 2 {
            await probe.enqueue(.init(status: 200, headers: ["ETag": "\"a\"", "Cache-Control": "no-store"], body: probe.png))
            _ = try await loader.image(for: key)
        }
        let requests = await probe.requests
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "If-None-Match") }, [nil, nil])
        XCTAssertEqual(requests.map(\.cachePolicy), [.useProtocolCachePolicy, .useProtocolCachePolicy])
    }

    func testConcurrentRevalidationsCoalesceAndCancellationKeepsStaleImage() async throws {
        let probe = try FetchProbe()
        await probe.enqueue(.init(status: 200, headers: ["ETag": "\"a\""], body: probe.png))
        let loader = InlineImageLoader(fetch: { try await probe.fetch($0) })
        let key = try key("coalesced")
        let stale = try await loader.image(for: key).image

        await probe.hold()
        let cancelled = Task { try await loader.image(for: key) }
        try await wait { await probe.requests.count == 2 }
        cancelled.cancel()
        _ = await cancelled.result
        try await wait { await probe.cancellations == 1 }

        await probe.enqueue(.init(status: 304, headers: [:]))
        let first = Task { try await loader.image(for: key).image }
        let second = Task { try await loader.image(for: key).image }
        try await wait { await probe.requests.count == 3 }
        try await Task.sleep(for: .milliseconds(30))
        await probe.release()
        let firstImage = try await first.value
        let secondImage = try await second.value
        XCTAssertTrue(stale === firstImage)
        XCTAssertTrue(stale === secondImage)
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "If-None-Match"), "\"a\"")
    }

    func testDecodingHasItsOwnLimitAndDoesNotHoldDownloadSlots() async throws {
        let fetches = try FetchProbe()
        let decodes = DecodeProbe()
        let loader = InlineImageLoader(
            maximumConcurrentLoads: 1,
            maximumConcurrentDecodes: 1,
            fetch: { request in
                let url = try XCTUnwrap(request.url)
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:]))
                await fetches.record(request)
                return (fetches.png, response)
            },
            decode: { data, key in try await decodes.decode(data, key: key) }
        )
        let tasks = try ["a", "b", "c"].map { name in
            let key = try key(name)
            return (name, Task { try await loader.image(for: key) })
        }
        // All downloads finish through one network slot while the first decode is still running.
        try await wait { await fetches.requests.count == 3 }
        try await wait { await decodes.started.count == 1 }
        try await Task.sleep(for: .milliseconds(30))
        var started = await decodes.started
        XCTAssertEqual(started.count, 1)

        // A job waiting for a decode slot can still be cancelled.
        let waiting = try XCTUnwrap(tasks.first { !started.contains($0.0) })
        waiting.1.cancel()
        _ = await waiting.1.result
        await decodes.release()
        for (name, task) in tasks where name != waiting.0 {
            _ = try await task.value
        }
        started = await decodes.started
        XCTAssertEqual(started.count, 2)
        XCTAssertFalse(started.contains(waiting.0))
    }

    func testImagesUseADedicatedBoundedSession() {
        let session = InlineImageLoader.session
        XCTAssertFalse(session === URLSession.shared)
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(session.configuration.httpMaximumConnectionsPerHost, 4)
        XCTAssertEqual(session.configuration.urlCache?.memoryCapacity, 20 * 1024 * 1024)
        XCTAssertEqual(session.configuration.urlCache?.diskCapacity, 200 * 1024 * 1024)
        XCTAssertFalse(session.configuration.urlCache === URLCache.shared)
    }

    private func key(_ name: String) throws -> InlineImageLoader.Key {
        .init(url: try XCTUnwrap(URL(string: "https://example.com/\(name)")), resolution: .original)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 200 {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for loader")
    }
}

private actor LoaderProbe {
    private(set) var started = 0
    private(set) var startedNames: [String] = []
    private(set) var cancellations = 0
    private var suspended: Bool

    init(suspended: Bool = true) {
        self.suspended = suspended
    }

    func release() {
        suspended = false
    }

    func load(_ key: InlineImageLoader.Key) async throws -> InlineImageLoader.Resource {
        started += 1
        startedNames.append(key.url.lastPathComponent)
        do {
            while suspended {
                try await Task.sleep(for: .milliseconds(5))
            }
            try Task.checkCancellation()
        } catch {
            cancellations += 1
            throw error
        }
        return .init(image: try makeImage(), expiration: Date().addingTimeInterval(60))
    }
}

/// Scripts HTTP responses and records the requests the loader sends.
private actor FetchProbe {
    struct Reply {
        var status: Int
        var headers: [String: String]
        var body = Data()
    }

    nonisolated let png: Data
    private(set) var requests: [URLRequest] = []
    private(set) var cancellations = 0
    private var replies: [Reply] = []
    private var suspended = false

    init() throws {
        png = try encodedPNG()
    }

    func enqueue(_ reply: Reply) {
        replies.append(reply)
    }

    func hold() {
        suspended = true
    }

    func release() {
        suspended = false
    }

    func record(_ request: URLRequest) {
        requests.append(request)
    }

    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        do {
            while suspended {
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch {
            cancellations += 1
            throw error
        }
        let reply = try XCTUnwrap(replies.first, "Unexpected request")
        replies.removeFirst()
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers
        ))
        return (reply.body, response)
    }
}

/// Suspends decoding until released and records which images started decoding.
private actor DecodeProbe {
    private(set) var started: [String] = []
    private var suspended = true

    func release() {
        suspended = false
    }

    func decode(_ data: Data, key: InlineImageLoader.Key) async throws -> InlineImageLoader.Decoded {
        started.append(key.url.lastPathComponent)
        while suspended {
            try await Task.sleep(for: .milliseconds(5))
        }
        return try InlineImageLoader.decode(data, resolution: key.resolution)
    }
}

private func encodedPNG(width: Int = 4, height: Int = 4) throws -> Data {
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try makeImage(width: width, height: height), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}

private func makeImage(width: Int = 4, height: Int = 4) throws -> CGImage {
    let context = try XCTUnwrap(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    return try XCTUnwrap(context.makeImage())
}

/// The clock is read by detached loading/expiration tasks and advanced by the test.
private final class ImageExpirationClock: Sendable {
    private let date = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1000))

    var now: Date {
        date.withLock { $0 }
    }

    func advance(by interval: TimeInterval) {
        date.withLock { $0.addTimeInterval(interval) }
    }
}

private actor ImageExpirationSleeper {
    private var continuation: CheckedContinuation<Void, Never>?

    var isSleeping: Bool {
        continuation != nil
    }

    func sleep(until deadline: Date) async {
        await withCheckedContinuation { continuation = $0 }
    }

    func wake() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

private final class WeakReference<Object: AnyObject> {
    weak var value: Object?

    init(_ value: Object?) {
        self.value = value
    }
}
