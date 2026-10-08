import Dispatch
import Foundation
import ImageIO

/// Shares decoded resources across paragraphs without sharing occurrence labels.
actor InlineImageLoader {
    struct Key: Hashable, Sendable {
        let url: URL
        let resolution: DefaultInlineImageProvider.Resolution
    }

    /// A decoded bitmap and the scale that keeps its natural layout size.
    ///
    /// Bitmaps decoded below their requested size have a scale below 1, so an `Image` created
    /// with it measures the same as one created from the full-size bitmap with a scale of 1.
    struct Decoded: Sendable {
        let image: CGImage
        let scale: CGFloat
    }

    /// HTTP validators that let a stale decoded image be revalidated instead of downloaded again.
    struct Validators: Hashable, Sendable {
        var entityTag: String?
        var lastModified: String?

        /// Returns `nil` when the response has no validators or must not be stored.
        init?(response: HTTPURLResponse, merging previous: Validators? = nil) {
            guard !InlineImageLoader.cacheDirectives(of: response).contains(where: { $0.hasPrefix("no-store") }) else {
                return nil
            }
            entityTag = response.value(forHTTPHeaderField: "ETag") ?? previous?.entityTag
            lastModified = response.value(forHTTPHeaderField: "Last-Modified") ?? previous?.lastModified
            guard entityTag != nil || lastModified != nil else {
                return nil
            }
        }
    }

    struct Resource: Sendable {
        let image: CGImage
        var scale: CGFloat = 1
        /// Reuse without contacting the server until this date.
        let expiration: Date?
        /// Reuse after a successful conditional request once the resource is stale.
        var validators: Validators?

        var decoded: Decoded {
            Decoded(image: image, scale: scale)
        }
    }

    enum LoadResult: Sendable {
        case loaded(Resource)
        /// The server confirmed that the revalidated image is still current.
        case notModified(expiration: Date?, validators: Validators?)
    }

    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Responses larger than this are rejected before they are buffered in full.
    static let maximumResponseByteCount = 50 * 1024 * 1024

    /// Images with more pixels than this (128 MB at 4 bytes per pixel) are decoded at a
    /// reduced size that keeps their natural layout size, whatever the requested resolution.
    static let maximumDecodedPixelCount = 32 * 1024 * 1024

    static let shared = InlineImageLoader()

    private struct Job {
        let key: Key
        /// The stale image a conditional request may confirm.
        let revalidating: (image: Decoded, validators: Validators)?
        var waiters: [UUID: CheckedContinuation<Decoded, any Error>]
    }

    private struct CachedImage {
        let image: Decoded
        let cost: Int
        /// `nil` once stale; stale entries are kept only when they have validators.
        var expiration: Date?
        var validators: Validators?
        var access: UInt64
    }

    private let maximumConcurrentLoads: Int
    private let maximumCacheCost: Int
    private let now: @Sendable () -> Date
    private let sleepUntil: @Sendable (Date) async throws -> Void
    private var expirationTask: Task<Void, Never>?
    private var scheduledExpiration: Date?
    private var expirationGeneration: UInt64 = 0
    private var memoryPressureObserver: MemoryPressureObserver?
    private let load: @Sendable (Key, Validators?) async throws -> LoadResult
    private var jobs: [UUID: Job] = [:]
    private var jobForKey: [Key: UUID] = [:]
    private var pending: [UUID] = []
    private var pendingHead = 0
    private(set) var pendingLoadCount = 0

    var pendingStorageCount: Int {
        pending.count
    }

    private var running: [UUID: Task<Void, Never>] = [:]
    private var cache: [Key: CachedImage] = [:]
    private var cacheCost = 0
    private var access: UInt64 = 0

    init(
        maximumConcurrentLoads: Int = 4,
        maximumCacheCost: Int = 64 * 1024 * 1024,
        now: @escaping @Sendable () -> Date = { Date() },
        sleepUntil: @escaping @Sendable (Date) async throws -> Void = { deadline in
            try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
        },
        fetch: @escaping Fetch = InlineImageLoader.fetch
    ) {
        self.init(
            maximumConcurrentLoads: maximumConcurrentLoads,
            maximumCacheCost: maximumCacheCost,
            now: now,
            sleepUntil: sleepUntil,
            loadResult: { key, validators in
                try await Self.load(key, validators: validators, fetch: fetch, now: now)
            }
        )
    }

    /// Loads resources without HTTP revalidation.
    init(
        maximumConcurrentLoads: Int = 4,
        maximumCacheCost: Int = 64 * 1024 * 1024,
        now: @escaping @Sendable () -> Date = { Date() },
        sleepUntil: @escaping @Sendable (Date) async throws -> Void = { deadline in
            try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
        },
        load: @escaping @Sendable (Key) async throws -> Resource
    ) {
        self.init(
            maximumConcurrentLoads: maximumConcurrentLoads,
            maximumCacheCost: maximumCacheCost,
            now: now,
            sleepUntil: sleepUntil,
            loadResult: { key, _ in .loaded(try await load(key)) }
        )
    }

    private init(
        maximumConcurrentLoads: Int,
        maximumCacheCost: Int,
        now: @escaping @Sendable () -> Date,
        sleepUntil: @escaping @Sendable (Date) async throws -> Void,
        loadResult: @escaping @Sendable (Key, Validators?) async throws -> LoadResult
    ) {
        precondition(maximumConcurrentLoads > 0 && maximumCacheCost >= 0)
        self.maximumConcurrentLoads = maximumConcurrentLoads
        self.maximumCacheCost = maximumCacheCost
        self.now = now
        self.sleepUntil = sleepUntil
        self.load = loadResult
    }

    deinit {
        expirationTask?.cancel()
    }

    func image(for key: Key) async throws -> Decoded {
        try Task.checkCancellation()
        var revalidating: (image: Decoded, validators: Validators)?
        if var cached = cache[key] {
            access &+= 1
            cached.access = access
            if let expiration = cached.expiration, expiration > now() {
                cache[key] = cached
                return cached.image
            }
            if let validators = cached.validators {
                // Keep the stale image so a 304 response can reuse it without decoding.
                cached.expiration = nil
                cache[key] = cached
                revalidating = (cached.image, validators)
            } else {
                cache.removeValue(forKey: key)
                cacheCost -= cached.cost
                scheduleExpiration()
            }
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Cancellation can arrive between entering this method and installing the handler.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let jobID = jobForKey[key] {
                    jobs[jobID]?.waiters[waiterID] = continuation
                } else {
                    let jobID = UUID()
                    jobs[jobID] = Job(key: key, revalidating: revalidating, waiters: [waiterID: continuation])
                    jobForKey[key] = jobID
                    pending.append(jobID)
                    pendingLoadCount += 1
                    startPendingLoads()
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID, key: key) }
        }
    }

    private func cancel(waiterID: UUID, key: Key) {
        guard let jobID = jobForKey[key],
              let continuation = jobs[jobID]?.waiters.removeValue(forKey: waiterID) else {
            return
        }
        continuation.resume(throwing: CancellationError())
        if jobs[jobID]?.waiters.isEmpty == true {
            jobs.removeValue(forKey: jobID)
            jobForKey.removeValue(forKey: key)
            if running[jobID] == nil {
                pendingLoadCount -= 1
                compactPendingIfNeeded()
            }
            // Keep the running slot occupied until cancellation has actually completed.
            running[jobID]?.cancel()
        }
    }

    private func startPendingLoads() {
        while running.count < maximumConcurrentLoads, pendingHead < pending.count {
            let jobID = pending[pendingHead]
            pendingHead += 1
            guard let job = jobs[jobID] else {
                continue
            }
            pendingLoadCount -= 1
            let load = self.load
            let validators = job.revalidating?.validators
            running[jobID] = Task.detached {
                let result: Result<LoadResult, any Error>
                do {
                    try Task.checkCancellation()
                    let image = try await load(job.key, validators)
                    try Task.checkCancellation()
                    result = .success(image)
                } catch {
                    result = .failure(error)
                }
                await self.finish(jobID: jobID, result: result)
            }
        }
        compactPendingIfNeeded()
    }

    /// Compact only after consuming/cancelling at least half the storage, so total
    /// bookkeeping stays amortized linear even if every running slot is occupied.
    private func compactPendingIfNeeded() {
        if pendingLoadCount == 0 {
            pending.removeAll(keepingCapacity: false)
            pendingHead = 0
        } else if pending.count >= 64, pendingLoadCount <= pending.count / 2 {
            pending = pending[pendingHead...].filter { jobs[$0] != nil }
            pendingHead = 0
        }
    }

    private func finish(jobID: UUID, result: Result<LoadResult, any Error>) {
        running.removeValue(forKey: jobID)
        if let job = jobs.removeValue(forKey: jobID) {
            jobForKey.removeValue(forKey: job.key)
            let image: Result<Decoded, any Error> = result.flatMap { result in
                switch result {
                    case let .loaded(resource):
                        insert(resource.decoded, expiration: resource.expiration, validators: resource.validators, for: job.key)
                        return .success(resource.decoded)
                    case let .notModified(expiration, validators):
                        guard let revalidated = job.revalidating?.image else {
                            return .failure(URLError(.badServerResponse))
                        }
                        insert(revalidated, expiration: expiration, validators: validators, for: job.key)
                        return .success(revalidated)
                }
            }
            for continuation in job.waiters.values {
                continuation.resume(with: image)
            }
        }
        startPendingLoads()
    }

    /// Caches fresh images until they expire and images with validators until they are evicted.
    private func insert(_ decoded: Decoded, expiration: Date?, validators: Validators?, for key: Key) {
        // A replacement or an uncacheable response supersedes any stale entry.
        if let replaced = cache.removeValue(forKey: key) {
            cacheCost -= replaced.cost
        }
        let expiration = expiration.flatMap { $0 > now() ? $0 : nil }
        guard expiration != nil || validators != nil else {
            return
        }
        let image = decoded.image
        let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !overflow, cost <= maximumCacheCost else {
            return
        }
        let targetCacheCost = maximumCacheCost - cost
        if cacheCost > targetCacheCost,
           let oldest = cache.min(by: { $0.value.access < $1.value.access }) {
            cacheCost -= oldest.value.cost
            cache.removeValue(forKey: oldest.key)
            if cacheCost > targetCacheCost {
                // Keep single-entry eviction linear, but order multiple victims only
                // once instead of rescanning the shrinking cache for every removal.
                let evictionOrder = cache.sorted { $0.value.access < $1.value.access }
                for (key, entry) in evictionOrder {
                    guard cacheCost > targetCacheCost else {
                        break
                    }
                    cacheCost -= entry.cost
                    cache.removeValue(forKey: key)
                }
            }
        }
        access &+= 1
        cache[key] = CachedImage(
            image: decoded, cost: cost, expiration: expiration, validators: validators, access: access
        )
        cacheCost += cost
        if memoryPressureObserver == nil {
            memoryPressureObserver = MemoryPressureObserver { [weak self] in
                Task { await self?.purgeCache() }
            }
        }
        // Keep the existing earlier wake-up: it also handles eviction of its original entry.
        if let expiration, scheduledExpiration.map({ expiration < $0 }) ?? true {
            scheduleExpiration(at: expiration)
        }
    }

    /// Releases decoded storage without disturbing downloads or their waiters.
    func purgeCache() {
        cache.removeAll(keepingCapacity: false)
        cacheCost = 0
        scheduleExpiration(at: nil)
    }

    private func scheduleExpiration() {
        scheduleExpiration(at: cache.values.lazy.compactMap(\.expiration).min())
    }

    private func scheduleExpiration(at deadline: Date?) {
        expirationTask?.cancel()
        expirationTask = nil
        scheduledExpiration = deadline
        expirationGeneration &+= 1
        guard let deadline else {
            return
        }
        let generation = expirationGeneration
        let sleepUntil = self.sleepUntil
        expirationTask = Task.detached { [weak self] in
            do {
                try await sleepUntil(deadline)
                try Task.checkCancellation()
            } catch {
                return
            }
            await self?.expireCache(generation: generation)
        }
    }

    private func expireCache(generation: UInt64) {
        guard generation == expirationGeneration else {
            return
        }
        let currentDate = now()
        for (key, entry) in cache {
            guard let expiration = entry.expiration, expiration <= currentDate else {
                continue
            }
            if entry.validators == nil {
                cache.removeValue(forKey: key)
                cacheCost -= entry.cost
            } else {
                // Stale images with validators stay cached for conditional requests.
                cache[key]?.expiration = nil
            }
        }
        scheduleExpiration()
    }

    /// Downloads and decodes a resource, or revalidates a stale one when validators are given.
    static func load(
        _ key: Key, validators: Validators?, fetch: Fetch, now: () -> Date
    ) async throws -> LoadResult {
        var request = URLRequest(url: key.url)
        if let validators {
            // Ask the server itself so URLCache can't turn its 304 into a stored 200 body.
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let entityTag = validators.entityTag {
                request.setValue(entityTag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastModified = validators.lastModified {
                request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }
        let (data, response) = try await fetch(request)
        try Task.checkCancellation()
        if response.statusCode == 304, validators != nil {
            return .notModified(
                expiration: cacheExpiration(for: response, now: now()),
                validators: Validators(response: response, merging: validators)
            )
        }
        guard 200 ..< 300 ~= response.statusCode else {
            throw URLError(.badServerResponse)
        }
        let decoded = try decode(data, resolution: key.resolution)
        return .loaded(Resource(
            image: decoded.image,
            scale: decoded.scale,
            expiration: cacheExpiration(for: response, now: now()),
            validators: Validators(response: response)
        ))
    }

    private static func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // Streaming the body lets oversized responses fail before they are fully buffered.
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (try await body(of: bytes, expectedContentLength: response.expectedContentLength), response)
    }

    /// Collects a response body, rejecting it once its declared or received size exceeds the limit.
    static func body<Bytes: AsyncSequence>(
        of bytes: Bytes, expectedContentLength: Int64, limit: Int = maximumResponseByteCount
    ) async throws -> Data where Bytes.Element == UInt8 {
        func tooLarge() -> URLError {
            URLError(.dataLengthExceedsMaximum, userInfo: [
                NSLocalizedDescriptionKey: "The image response is larger than the \(limit)-byte limit."
            ])
        }
        guard expectedContentLength <= limit else {
            throw tooLarge()
        }
        var body: [UInt8] = []
        body.reserveCapacity(max(0, Int(expectedContentLength)))
        for try await byte in bytes {
            guard body.count < limit else {
                throw tooLarge()
            }
            body.append(byte)
        }
        try Task.checkCancellation()
        return Data(body)
    }

    /// Configured once and never mutated afterwards. `DateFormatter` is documented as thread safe
    /// for formatting and parsing on the supported OS versions, so concurrent downloads may share it.
    private nonisolated(unsafe) static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter
    }()

    static func cacheDirectives(of response: HTTPURLResponse) -> [String] {
        (response.value(forHTTPHeaderField: "Cache-Control") ?? "")
            .lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Honor explicit freshness only; stale images with validators are revalidated instead.
    static func cacheExpiration(for response: HTTPURLResponse, now: Date = Date()) -> Date? {
        let directives = cacheDirectives(of: response)
        guard !directives.contains(where: { $0.hasPrefix("no-store") || $0.hasPrefix("no-cache") }),
              let maxAge = directives.first(where: { $0.hasPrefix("max-age=") }),
              let seconds = TimeInterval(maxAge.dropFirst("max-age=".count)
                  .trimmingCharacters(in: CharacterSet(charactersIn: "\""))), seconds > 0 else {
            return nil
        }
        var age = max(0, TimeInterval(response.value(forHTTPHeaderField: "Age") ?? "0") ?? 0)
        if let dateHeader = response.value(forHTTPHeaderField: "Date"),
           let date = httpDateFormatter.date(from: dateHeader) {
            age = max(age, now.timeIntervalSince(date))
        }
        // A short upper bound also limits freshness when a server advertises a long lifetime.
        let lifetime = min(60, max(0, seconds - age))
        return lifetime > 0 ? now.addingTimeInterval(lifetime) : nil
    }

    static func decode(
        _ data: Data,
        resolution: DefaultInlineImageProvider.Resolution,
        maximumPixelCount: Int = maximumDecodedPixelCount
    ) throws -> Decoded {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw URLError(.cannotDecodeContentData)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw URLError(.cannotDecodeContentData)
        }
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)
            .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up

        // Pixel dimensions come from the header, so oversized images never decode at full size.
        let longestSide = max(width, height)
        let (layoutLongestSide, decodingLimit) = switch resolution {
            case .original: (longestSide, longestSide)
            case let .maximumPixelDimension(dimension): (min(longestSide, dimension), min(longestSide, dimension))
            case let .downsampled(dimension): (longestSide, min(longestSide, dimension))
        }
        let pixelBudgetScale = (Double(maximumPixelCount) / (Double(width) * Double(height))).squareRoot()
        let decodedLongestSide = max(1, Int(min(Double(decodingLimit), Double(longestSide) * pixelBudgetScale)))

        let image: CGImage? = if decodedLongestSide == longestSide, orientation == .up {
            CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        } else {
            // CGImage has no orientation metadata, so thumbnails also normalize the pixels
            // without first decoding a second bitmap.
            thumbnail(source, maximumPixelDimension: decodedLongestSide)
        }
        try Task.checkCancellation()
        guard let image else {
            throw URLError(.cannotDecodeContentData)
        }
        let scale = CGFloat(max(image.width, image.height)) / CGFloat(layoutLongestSide)
        return Decoded(image: image, scale: decodedLongestSide == layoutLongestSide ? 1 : scale)
    }

    private static func thumbnail(_ source: CGImageSource, maximumPixelDimension: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension
        ] as CFDictionary)
    }
}

/// Owns an immutable, resumed dispatch source; callbacks only hop onto the loader actor.
private final class MemoryPressureObserver: @unchecked Sendable {
    private let source: any DispatchSourceMemoryPressure

    init(handler: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
        source.setEventHandler(handler: handler)
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
