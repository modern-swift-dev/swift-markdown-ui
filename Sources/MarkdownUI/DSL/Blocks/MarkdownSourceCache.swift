import os

/// A bounded cache of the Markdown strings that ``MarkdownContentBuilder`` parses.
///
/// Builder closures run again whenever a parent view evaluates its body, so their strings
/// would otherwise be parsed on every update. The cache evicts the least recently used
/// sources beyond an entry count and a combined UTF-8 byte count; larger sources bypass
/// it. Concurrent misses may parse a source more than once; parsing happens outside the lock.
final class MarkdownSourceCache: Sendable {
    static let shared = MarkdownSourceCache()

    private struct Entry {
        var content: MarkdownContent
        var lastUse: UInt64
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var byteCount = 0
        var clock: UInt64 = 0

        mutating func use(_ source: String) -> MarkdownContent? {
            guard self.entries[source] != nil else {
                return nil
            }
            self.clock += 1
            self.entries[source]?.lastUse = self.clock
            return self.entries[source]?.content
        }
    }

    private let maximumEntryCount: Int
    private let maximumByteCount: Int
    private let parse: @Sendable (String) -> MarkdownContent
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        maximumEntryCount: Int = 128,
        maximumByteCount: Int = 256 * 1024,
        parse: @escaping @Sendable (String) -> MarkdownContent = { MarkdownContent($0) }
    ) {
        self.maximumEntryCount = max(0, maximumEntryCount)
        self.maximumByteCount = max(0, maximumByteCount)
        self.parse = parse
    }

    func content(for source: String) -> MarkdownContent {
        let byteCount = source.utf8.count
        guard self.maximumEntryCount > 0, byteCount <= self.maximumByteCount else {
            return self.parse(source)
        }
        if let cached = self.state.withLock({ $0.use(source) }) {
            return cached
        }

        let content = self.parse(source)
        return self.state.withLock { state in
            if let cached = state.use(source) {
                return cached
            }
            state.clock += 1
            state.entries[source] = Entry(content: content, lastUse: state.clock)
            state.byteCount += byteCount
            while state.entries.count > self.maximumEntryCount || state.byteCount > self.maximumByteCount,
                  let oldest = state.entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
                state.entries.removeValue(forKey: oldest)
                state.byteCount -= oldest.utf8.count
            }
            return content
        }
    }

    /// Returns the cached content for a source without parsing it or marking it as used.
    func cachedContent(for source: String) -> MarkdownContent? {
        self.state.withLock { $0.entries[source]?.content }
    }
}
