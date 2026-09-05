import Foundation
import ImageIO

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit) || canImport(AppKit)
/// Provider-scoped resource sharing preserves native platform image decoding and sizing.
@MainActor final class MarkdownEditorImageLoader {
    struct Resource {
        let image: MarkdownEditorPlatformImage
        let cost: Int
        let expiration: Date?
    }

    private final class CachedImage {
        let resource: Resource
        init(_ resource: Resource) {
            self.resource = resource
        }
    }

    private struct Job {
        let url: URL
        var waiters: [UUID: CheckedContinuation<MarkdownEditorPlatformImage, any Error>]
    }

    private let cache = NSCache<NSURL, CachedImage>()
    private let maximumCacheCost: Int
    private let load: @MainActor (URL) async throws -> Resource
    private var jobs: [UUID: Job] = [:]
    private var jobForURL: [URL: UUID] = [:]
    private var pending: [UUID] = []
    private var running: [UUID: Task<Void, Never>] = [:]

    init(
        maximumCacheCost: Int = 64 * 1024 * 1024,
        load: @escaping @MainActor (URL) async throws -> Resource = MarkdownEditorImageLoader.download
    ) {
        precondition(maximumCacheCost >= 0)
        self.maximumCacheCost = maximumCacheCost
        self.load = load
        cache.totalCostLimit = maximumCacheCost
        cache.countLimit = 128
    }

    func image(for url: URL) async throws -> MarkdownEditorPlatformImage {
        try Task.checkCancellation()
        if let resource = cache.object(forKey: url as NSURL)?.resource,
           let expiration = resource.expiration, expiration > Date() {
            return resource.image
        }
        cache.removeObject(forKey: url as NSURL)
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
                    jobs[jobID] = Job(url: url, waiters: [waiterID: continuation])
                    jobForURL[url] = jobID
                    pending.append(jobID)
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
            pending.removeAll { $0 == jobID }
            running[jobID]?.cancel()
        }
    }

    private func startPendingLoads() {
        while running.count < 4, !pending.isEmpty {
            let jobID = pending.removeFirst()
            guard let job = jobs[jobID] else {
                continue
            }
            let load = self.load
            running[jobID] = Task { @MainActor in
                let result: Result<Resource, any Error>
                do {
                    try Task.checkCancellation()
                    let resource = try await load(job.url)
                    try Task.checkCancellation()
                    result = .success(resource)
                } catch {
                    result = .failure(error)
                }
                self.finish(jobID: jobID, result: result)
            }
        }
    }

    private func finish(jobID: UUID, result: Result<Resource, any Error>) {
        running.removeValue(forKey: jobID)
        if let job = jobs.removeValue(forKey: jobID) {
            jobForURL.removeValue(forKey: job.url)
            if case let .success(resource) = result,
               resource.cost > 0, resource.cost <= maximumCacheCost,
               let expiration = resource.expiration, expiration > Date() {
                cache.setObject(CachedImage(resource), forKey: job.url as NSURL, cost: resource.cost)
            }
            for continuation in job.waiters.values {
                continuation.resume(with: result.map(\.image))
            }
        }
        startPendingLoads()
    }

    private static func download(_ url: URL) async throws -> Resource {
        let (data, response) = try await URLSession.shared.data(from: url)
        try Task.checkCancellation()
        // Read dimensions without changing NSImage/UIImage's original decoding or intrinsic sizing.
        let cost: Int
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
            let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 8)
            let (allFrames, framesOverflow) = bytes.multipliedReportingOverflow(by: CGImageSourceGetCount(source))
            cost = overflow || byteOverflow || framesOverflow ? Int.max : max(data.count, allFrames)
        } else {
            cost = Int.max
        }
        try Task.checkCancellation()
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else {
            throw MarkdownEditorImageProviderError.invalidImageData
        }
        #else
        guard let image = NSImage(data: data) else {
            throw MarkdownEditorImageProviderError.invalidImageData
        }
        #endif
        try Task.checkCancellation()
        return Resource(image: image, cost: cost, expiration: (response as? HTTPURLResponse).flatMap {
            cacheExpiration(for: $0)
        })
    }

    /// Defer heuristic freshness/revalidation to URLSession; retain explicit freshness for at most a minute.
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
        let lifetime = min(60, max(0, seconds - age))
        return lifetime > 0 ? now.addingTimeInterval(lifetime) : nil
    }
}
#endif
