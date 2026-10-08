import Foundation
import ImageIO

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

#if canImport(UIKit) || canImport(AppKit)
    /// Provider-scoped resource sharing that decodes off the main actor at display resolution
    /// while preserving the point size of native platform image decoding.
    @MainActor final class MarkdownEditorImageLoader {
        /// HTTP validators that let a stale decoded image be revalidated instead of downloaded again.
        struct Validators: Hashable, Sendable {
            var entityTag: String?
            var lastModified: String?

            /// Returns `nil` when the response has no validators or must not be stored.
            init?(response: HTTPURLResponse, merging previous: Validators? = nil) {
                guard !MarkdownEditorImageLoader.cacheDirectives(of: response).contains(where: { $0.hasPrefix("no-store") }) else {
                    return nil
                }
                entityTag = response.value(forHTTPHeaderField: "ETag") ?? previous?.entityTag
                lastModified = response.value(forHTTPHeaderField: "Last-Modified") ?? previous?.lastModified
                guard entityTag != nil || lastModified != nil else {
                    return nil
                }
            }
        }

        struct Resource {
            let image: MarkdownEditorPlatformImage
            let cost: Int
            /// Reuse without contacting the server until this date.
            let expiration: Date?
            /// Reuse after a successful conditional request once the resource is stale.
            var validators: Validators?
        }

        enum LoadResult {
            case loaded(Resource)
            /// The server confirmed that the revalidated image is still current.
            case notModified(expiration: Date?, validators: Validators?)
        }

        typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

        private final class CachedImage {
            let resource: Resource
            init(_ resource: Resource) {
                self.resource = resource
            }
        }

        private struct Job {
            let url: URL
            /// The stale image a conditional request may confirm.
            let revalidating: Resource?
            var waiters: [UUID: CheckedContinuation<MarkdownEditorPlatformImage, any Error>]
        }

        private let cache = NSCache<NSURL, CachedImage>()
        private let maximumCacheCost: Int
        private let now: @MainActor () -> Date
        private let sleepUntil: @MainActor (Date) async throws -> Void
        private var latestExpiration: Date?
        /// Entries without validators, which idle expiry releases. NSCache can't enumerate its keys,
        /// and entries with validators stay cached for conditional requests until NSCache evicts them.
        private var expiringURLs: Set<URL> = []
        private var expirationTask: Task<Void, Never>?
        private let load: @MainActor (URL, Validators?) async throws -> LoadResult
        private var jobs: [UUID: Job] = [:]
        private var jobForURL: [URL: UUID] = [:]
        private var pending: [UUID] = []
        private var pendingHead = 0
        private(set) var pendingLoadCount = 0
        private var running: [UUID: Task<Void, Never>] = [:]

        /// The loader behind every `MarkdownURLSessionImageProvider()`, so editors share one cache.
        static let shared = MarkdownEditorImageLoader()

        /// Responses larger than this are rejected before they are buffered in full.
        nonisolated static let maximumResponseByteCount = 50 * 1024 * 1024

        /// Images with more pixels than this (512 MB at 4 bytes per pixel) are rejected before decoding.
        nonisolated static let maximumPixelCount = 128 * 1024 * 1024

        var pendingStorageCount: Int {
            pending.count
        }

        convenience init(
            maximumCacheCost: Int = 64 * 1024 * 1024,
            now: @escaping @MainActor () -> Date = { Date() },
            sleepUntil: @escaping @MainActor (Date) async throws -> Void = { deadline in
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            },
            fetch: @escaping Fetch = MarkdownEditorImageLoader.fetch
        ) {
            self.init(maximumCacheCost: maximumCacheCost, now: now, sleepUntil: sleepUntil, loadResult: { url, validators in
                try await MarkdownEditorImageLoader.load(
                    url, validators: validators, maximumPixelSize: MarkdownEditorImageLoader.maximumPixelSize(), fetch: fetch
                )
            })
        }

        /// Loads resources without HTTP revalidation.
        convenience init(
            maximumCacheCost: Int = 64 * 1024 * 1024,
            now: @escaping @MainActor () -> Date = { Date() },
            sleepUntil: @escaping @MainActor (Date) async throws -> Void = { deadline in
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            },
            load: @escaping @MainActor (URL) async throws -> Resource
        ) {
            self.init(maximumCacheCost: maximumCacheCost, now: now, sleepUntil: sleepUntil, loadResult: { url, _ in
                try await .loaded(load(url))
            })
        }

        private init(
            maximumCacheCost: Int,
            now: @escaping @MainActor () -> Date,
            sleepUntil: @escaping @MainActor (Date) async throws -> Void,
            loadResult load: @escaping @MainActor (URL, Validators?) async throws -> LoadResult
        ) {
            precondition(maximumCacheCost >= 0)
            self.maximumCacheCost = maximumCacheCost
            self.now = now
            self.sleepUntil = sleepUntil
            self.load = load
            cache.totalCostLimit = maximumCacheCost
            cache.countLimit = 128
        }

        deinit {
            expirationTask?.cancel()
        }

        func image(for url: URL) async throws -> MarkdownEditorPlatformImage {
            try Task.checkCancellation()
            var revalidating: Resource?
            if let resource = cache.object(forKey: url as NSURL)?.resource {
                if let expiration = resource.expiration, expiration > now() {
                    return resource.image
                }
                if resource.validators != nil {
                    // Keep the stale image so a 304 response can reuse it without decoding.
                    revalidating = resource
                } else {
                    removeCachedImage(for: url)
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
                    if let jobID = jobForURL[url] {
                        jobs[jobID]?.waiters[waiterID] = continuation
                    } else {
                        let jobID = UUID()
                        jobs[jobID] = Job(url: url, revalidating: revalidating, waiters: [waiterID: continuation])
                        jobForURL[url] = jobID
                        pending.append(jobID)
                        pendingLoadCount += 1
                        startPendingLoads()
                    }
                }
            } onCancel: {
                Task { @MainActor in self.cancel(waiterID: waiterID, url: url) }
            }
        }

        private func cancel(waiterID: UUID, url: URL) {
            guard let jobID = jobForURL[url],
                  let continuation = jobs[jobID]?.waiters.removeValue(forKey: waiterID) else {
                return
            }
            continuation.resume(throwing: CancellationError())
            if jobs[jobID]?.waiters.isEmpty == true {
                jobs.removeValue(forKey: jobID)
                jobForURL.removeValue(forKey: url)
                if running[jobID] == nil {
                    pendingLoadCount -= 1
                    compactPendingIfNeeded()
                }
                // Cancellation keeps its slot occupied until the load actually finishes.
                running[jobID]?.cancel()
            }
        }

        private func startPendingLoads() {
            while running.count < 4, pendingHead < pending.count {
                let jobID = pending[pendingHead]
                pendingHead += 1
                guard let job = jobs[jobID] else {
                    continue
                }
                pendingLoadCount -= 1
                let load = self.load
                running[jobID] = Task { @MainActor in
                    let result: Result<LoadResult, any Error>
                    do {
                        try Task.checkCancellation()
                        let loaded = try await load(job.url, job.revalidating?.validators)
                        try Task.checkCancellation()
                        result = .success(loaded)
                    } catch {
                        result = .failure(error)
                    }
                    self.finish(jobID: jobID, result: result)
                }
            }
            compactPendingIfNeeded()
        }

        /// Reclaim consumed and cancelled entries only after at least half the
        /// storage is unused, keeping queue bookkeeping amortized linear.
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
                jobForURL.removeValue(forKey: job.url)
                let image: Result<MarkdownEditorPlatformImage, any Error> = result.flatMap { result in
                    switch result {
                        case let .loaded(resource):
                            insert(resource, for: job.url)
                            return .success(resource.image)
                        case let .notModified(expiration, validators):
                            guard let stale = job.revalidating else {
                                return .failure(URLError(.badServerResponse))
                            }
                            insert(Resource(image: stale.image, cost: stale.cost, expiration: expiration, validators: validators), for: job.url)
                            return .success(stale.image)
                    }
                }
                for continuation in job.waiters.values {
                    continuation.resume(with: image)
                }
            }
            startPendingLoads()
        }

        /// Caches fresh images until they expire and images with validators until NSCache evicts them.
        private func insert(_ resource: Resource, for url: URL) {
            // A replacement or an uncacheable response supersedes any stale entry.
            removeCachedImage(for: url)
            let expiration = resource.expiration.flatMap { $0 > now() ? $0 : nil }
            guard resource.cost > 0, resource.cost <= maximumCacheCost,
                  expiration != nil || resource.validators != nil else {
                return
            }
            cache.setObject(CachedImage(resource), forKey: url as NSURL, cost: resource.cost)
            guard resource.validators == nil, let expiration else {
                return
            }
            expiringURLs.insert(url)
            if expiringURLs.count > 2 * cache.countLimit {
                // Forget entries NSCache already evicted, keeping this index bounded between idle periods.
                expiringURLs = expiringURLs.filter { cache.object(forKey: $0 as NSURL) != nil }
            }
            latestExpiration = max(latestExpiration ?? expiration, expiration)
            if expirationTask == nil {
                scheduleExpiration(at: expiration)
            }
        }

        private func removeCachedImage(for url: URL) {
            cache.removeObject(forKey: url as NSURL)
            expiringURLs.remove(url)
        }

        private func scheduleExpiration(at deadline: Date) {
            let sleepUntil = self.sleepUntil
            expirationTask = Task { @MainActor [weak self] in
                do {
                    try await sleepUntil(deadline)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                self?.expireIdleCache()
            }
        }

        /// Release images without validators once every such resource has expired. Individual
        /// expired entries may remain until the newest deadline (at most one minute after the
        /// last download); NSCache still governs cost and count meanwhile. One deadline and one
        /// task avoid a timer per entry; images with validators stay for conditional requests.
        private func expireIdleCache() {
            expirationTask = nil
            guard let latestExpiration else {
                return
            }
            if latestExpiration > now() {
                scheduleExpiration(at: latestExpiration)
            } else {
                for url in expiringURLs {
                    cache.removeObject(forKey: url as NSURL)
                }
                expiringURLs.removeAll()
                self.latestExpiration = nil
            }
        }

        /// The longest pixel side worth decoding: attachment views draw images aspect-fit into
        /// a fixed box, so no image is drawn larger than the box's longest side.
        static func maximumPixelSize() -> Int {
            #if canImport(UIKit)
                let scale = UITraitCollection.current.displayScale
            #else
                let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 0
            #endif
            let size = MarkdownImageAttachment.imageViewSize
            return Int((max(size.width, size.height) * (scale > 0 ? scale : 3)).rounded(.up))
        }

        /// Downloads and decodes a resource, or revalidates a stale one when validators are given.
        nonisolated static func load(
            _ url: URL, validators: Validators?, maximumPixelSize: Int, fetch: Fetch
        ) async throws -> LoadResult {
            var request = URLRequest(url: url)
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
            let httpResponse = response as? HTTPURLResponse
            if let httpResponse, httpResponse.statusCode == 304, validators != nil {
                return .notModified(
                    expiration: cacheExpiration(for: httpResponse),
                    validators: Validators(response: httpResponse, merging: validators)
                )
            }
            if let httpResponse, !(200 ..< 300 ~= httpResponse.statusCode) {
                throw URLError(.badServerResponse)
            }
            let (image, cost) = try decode(data, maximumPixelSize: maximumPixelSize)
            try Task.checkCancellation()
            return .loaded(Resource(
                image: image,
                cost: cost,
                expiration: httpResponse.flatMap { cacheExpiration(for: $0) },
                validators: httpResponse.flatMap { Validators(response: $0) }
            ))
        }

        /// A session created on first use, so its HTTP cache stays separate from `URLSession.shared`.
        nonisolated static let session: URLSession = {
            let configuration = URLSessionConfiguration.default
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("MarkdownUIEditor.MarkdownEditorImageLoader", isDirectory: true)
            configuration.urlCache = URLCache(
                memoryCapacity: 20 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024, directory: directory
            )
            configuration.timeoutIntervalForRequest = 15
            configuration.httpMaximumConnectionsPerHost = 4
            return URLSession(configuration: configuration)
        }()

        nonisolated static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
            try await fetch(request, session: session)
        }

        /// Fetches a response body; HTTP error and 304 bodies are never read, since they aren't decoded.
        nonisolated static func fetch(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
            // Streaming the body lets oversized responses fail before they are fully buffered.
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            if let response = response as? HTTPURLResponse, !(200 ..< 300 ~= response.statusCode) {
                return (Data(), response)
            }
            return (try await body(of: bytes, expectedContentLength: response.expectedContentLength), response)
        }

        /// Collects a response body, rejecting it once its declared or received size exceeds the limit.
        nonisolated static func body<Bytes: AsyncSequence>(
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

        /// Decodes a fully rendered bitmap no larger than `maximumPixelSize`, so drawing on the main
        /// actor doesn't decode. The image reports the point size `UIImage(data:)` or `NSImage(data:)`
        /// would, including EXIF orientation and, on AppKit, DPI metadata.
        nonisolated static func decode(
            _ data: Data, maximumPixelSize: Int, maximumPixelCount: Int = maximumPixelCount
        ) throws -> (image: MarkdownEditorPlatformImage, cost: Int) {
            try Task.checkCancellation()
            let source = CGImageSourceCreateWithData(data as CFData, nil)
            let index = source.map(CGImageSourceGetPrimaryImageIndex) ?? 0
            guard let source,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0 else {
                // Formats ImageIO can't describe keep their native decoding and are never cached.
                return (try nativeImage(data), Int.max)
            }
            let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
            // Header dimensions are checked first, so a small file can't claim a huge bitmap.
            guard !overflow, pixels <= maximumPixelCount else {
                throw URLError(.cannotDecodeContentData, userInfo: [
                    NSLocalizedDescriptionKey: "The image's \(width)×\(height) pixels exceed the \(maximumPixelCount)-pixel limit."
                ])
            }
            // Native images keep the encoded data and decode one 4-byte-per-pixel frame when drawn.
            let (nativeCost, nativeOverflow) = data.count.addingReportingOverflow(pixels * 4)
            #if !canImport(UIKit)
                // NSImageView animates multi-frame bitmaps such as GIFs, which a single thumbnail can't.
                if CGImageSourceGetCount(source) > 1 {
                    return (try nativeImage(data), nativeOverflow ? Int.max : nativeCost)
                }
            #endif
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)
                .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
            let swapsAxes = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
            let orientedWidth = swapsAxes ? height : width
            let orientedHeight = swapsAxes ? width : height
            guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, min(maximumPixelSize, max(width, height)))
            ] as CFDictionary) else {
                return (try nativeImage(data), nativeOverflow ? Int.max : nativeCost)
            }
            try Task.checkCancellation()
            // Only this bitmap is retained; the encoded data and any other frames are released.
            let (bitmapCost, bitmapOverflow) = bitmap.bytesPerRow.multipliedReportingOverflow(by: bitmap.height)
            let cost = bitmapOverflow ? Int.max : bitmapCost
            #if canImport(UIKit)
                // UIImage(data:) has a scale of 1, so a smaller bitmap gets a proportionally smaller scale.
                let scale = CGFloat(max(bitmap.width, bitmap.height)) / CGFloat(max(orientedWidth, orientedHeight))
                return (UIImage(cgImage: bitmap, scale: scale, orientation: .up), cost)
            #else
                // NSImage(data:) measures each oriented axis at 72 / DPI points per pixel.
                func points(_ pixels: Int, dpi key: CFString) -> CGFloat {
                    let dpi = (properties[key] as? NSNumber)?.doubleValue ?? 72
                    return CGFloat(pixels) * 72 / (dpi > 0 ? dpi : 72)
                }
                let size = NSSize(
                    width: points(orientedWidth, dpi: kCGImagePropertyDPIWidth),
                    height: points(orientedHeight, dpi: kCGImagePropertyDPIHeight)
                )
                return (NSImage(cgImage: bitmap, size: size), cost)
            #endif
        }

        private nonisolated static func nativeImage(_ data: Data) throws -> MarkdownEditorPlatformImage {
            #if canImport(UIKit)
                guard let image = UIImage(data: data) else {
                    throw MarkdownEditorImageProviderError.invalidImageData
                }
            #else
                guard let image = NSImage(data: data) else {
                    throw MarkdownEditorImageProviderError.invalidImageData
                }
            #endif
            return image
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

        nonisolated static func cacheDirectives(of response: HTTPURLResponse) -> [String] {
            (response.value(forHTTPHeaderField: "Cache-Control") ?? "")
                .lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        /// Honor explicit freshness for at most a minute; stale images with validators are revalidated instead.
        nonisolated static func cacheExpiration(for response: HTTPURLResponse, now: Date = Date()) -> Date? {
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
            let lifetime = min(60, max(0, seconds - age))
            return lifetime > 0 ? now.addingTimeInterval(lifetime) : nil
        }
    }
#endif
