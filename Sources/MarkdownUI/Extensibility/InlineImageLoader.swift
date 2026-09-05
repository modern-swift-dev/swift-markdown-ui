import Dispatch
import Foundation
import ImageIO

/// Shares decoded resources across paragraphs without sharing occurrence labels.
actor InlineImageLoader {
    struct Key: Hashable, Sendable {
        let url: URL
        let resolution: DefaultInlineImageProvider.Resolution
    }

    struct Resource: Sendable {
        let image: CGImage
        let expiration: Date?
    }

    static let shared = InlineImageLoader()

    private struct Job {
        let key: Key
        var waiters: [UUID: CheckedContinuation<CGImage, any Error>]
    }

    private struct CachedImage {
        let image: CGImage
        let cost: Int
        let expiration: Date
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
    private let load: @Sendable (Key) async throws -> Resource
    private var jobs: [UUID: Job] = [:]
    private var jobForKey: [Key: UUID] = [:]
    private var pending: [UUID] = []
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
        load: @escaping @Sendable (Key) async throws -> Resource = InlineImageLoader.download
    ) {
        precondition(maximumConcurrentLoads > 0 && maximumCacheCost >= 0)
        self.maximumConcurrentLoads = maximumConcurrentLoads
        self.maximumCacheCost = maximumCacheCost
        self.now = now
        self.sleepUntil = sleepUntil
        self.load = load
    }

    deinit {
        expirationTask?.cancel()
    }

    func image(for key: Key) async throws -> CGImage {
        try Task.checkCancellation()
        if var cached = cache[key], cached.expiration > now() {
            access &+= 1
            cached.access = access
            cache[key] = cached
            return cached.image
        }
        if let expired = cache.removeValue(forKey: key) {
            cacheCost -= expired.cost
            scheduleExpiration()
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
                    jobs[jobID] = Job(key: key, waiters: [waiterID: continuation])
                    jobForKey[key] = jobID
                    pending.append(jobID)
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
            pending.removeAll { $0 == jobID }
            // Keep the running slot occupied until cancellation has actually completed.
            running[jobID]?.cancel()
        }
    }

    private func startPendingLoads() {
        while running.count < maximumConcurrentLoads, !pending.isEmpty {
            let jobID = pending.removeFirst()
            guard let job = jobs[jobID] else {
                continue
            }
            let load = self.load
            running[jobID] = Task.detached {
                let result: Result<Resource, any Error>
                do {
                    try Task.checkCancellation()
                    let image = try await load(job.key)
                    try Task.checkCancellation()
                    result = .success(image)
                } catch {
                    result = .failure(error)
                }
                await self.finish(jobID: jobID, result: result)
            }
        }
    }

    private func finish(jobID: UUID, result: Result<Resource, any Error>) {
        running.removeValue(forKey: jobID)
        if let job = jobs.removeValue(forKey: jobID) {
            jobForKey.removeValue(forKey: job.key)
            if case let .success(resource) = result {
                insert(resource, for: job.key)
            }
            for continuation in job.waiters.values {
                continuation.resume(with: result.map(\.image))
            }
        }
        startPendingLoads()
    }

    private func insert(_ resource: Resource, for key: Key) {
        guard let expiration = resource.expiration, expiration > now() else {
            return
        }
        let image = resource.image
        let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !overflow, cost <= maximumCacheCost else {
            return
        }
        while cacheCost > maximumCacheCost - cost,
              let oldest = cache.min(by: { $0.value.access < $1.value.access }) {
            cacheCost -= oldest.value.cost
            cache.removeValue(forKey: oldest.key)
        }
        access &+= 1
        cache[key] = CachedImage(image: image, cost: cost, expiration: expiration, access: access)
        cacheCost += cost
        if memoryPressureObserver == nil {
            memoryPressureObserver = MemoryPressureObserver { [weak self] in
                Task { await self?.purgeCache() }
            }
        }
        // Keep the existing earlier wake-up: it also handles eviction of its original entry.
        if scheduledExpiration.map({ expiration < $0 }) ?? true {
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
        scheduleExpiration(at: cache.values.lazy.map(\.expiration).min())
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
        for (key, entry) in cache where entry.expiration <= currentDate {
            cache.removeValue(forKey: key)
            cacheCost -= entry.cost
        }
        scheduleExpiration()
    }

    private static func download(_ key: Key) async throws -> Resource {
        let (data, response) = try await URLSession.shared.data(from: key.url)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              200 ..< 300 ~= response.statusCode else {
            throw URLError(.badServerResponse)
        }
        return Resource(
            image: try decode(data, resolution: key.resolution),
            expiration: cacheExpiration(for: response)
        )
    }

    /// Honor explicit freshness only; URLSession owns revalidation and heuristic HTTP caching.
    static func cacheExpiration(for response: HTTPURLResponse, now: Date = Date()) -> Date? {
        let directives = (response.value(forHTTPHeaderField: "Cache-Control") ?? "")
            .lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !directives.contains(where: { $0.hasPrefix("no-store") || $0.hasPrefix("no-cache") }),
              let maxAge = directives.first(where: { $0.hasPrefix("max-age=") }),
              let seconds = TimeInterval(maxAge.dropFirst("max-age=".count)
                  .trimmingCharacters(in: CharacterSet(charactersIn: "\""))), seconds > 0 else {
            return nil
        }
        var age = max(0, TimeInterval(response.value(forHTTPHeaderField: "Age") ?? "0") ?? 0)
        if let dateHeader = response.value(forHTTPHeaderField: "Date") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            if let date = formatter.date(from: dateHeader) {
                age = max(age, now.timeIntervalSince(date))
            }
        }
        // A short upper bound also limits freshness when a server advertises a long lifetime.
        let lifetime = min(60, max(0, seconds - age))
        return lifetime > 0 ? now.addingTimeInterval(lifetime) : nil
    }

    static func decode(_ data: Data, resolution: DefaultInlineImageProvider.Resolution) throws -> CGImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw URLError(.cannotDecodeContentData)
        }
        let image: CGImage? = switch resolution {
            case .original:
                CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            case let .maximumPixelDimension(dimension):
                CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: dimension
                ] as CFDictionary)
        }
        try Task.checkCancellation()
        guard let image else {
            throw URLError(.cannotDecodeContentData)
        }
        return image
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
