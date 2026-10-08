import os
import SwiftUI

/// A bounded cache of the text returned by another syntax highlighter.
///
/// Retain this wrapper across view updates so repeated code blocks reuse their
/// highlighted text. Its key contains the code and language. Use it only when the
/// wrapped highlighter produces the same result for those inputs, and create a
/// new wrapper when the highlighter's configuration (such as its theme) changes.
///
/// The cache evicts the least recently used entry. Entry and source-size limits bound
/// retained inputs and result count, rather than the exact memory used by `Text`.
/// Concurrent misses may invoke the wrapped highlighter more than once; cache
/// access is synchronized without holding a lock while calling user code.
public struct CachedCodeSyntaxHighlighter<Base: CodeSyntaxHighlighter>: CodeSyntaxHighlighter {
    private typealias Key = CodeSyntaxHighlighterCacheKey

    private struct Entry {
        var key: Key
        var text: Text
        var older: Int?
        var newer: Int?
    }

    /// Entries form a recency list over array slots, so hits and evictions take constant time.
    private struct State {
        var indices: [Key: Int] = [:]
        var entries: [Entry] = []
        var oldest: Int?
        var newest: Int?

        mutating func text(for key: Key) -> Text? {
            guard let index = self.indices[key] else {
                return nil
            }
            self.markRecentlyUsed(index)
            return self.entries[index].text
        }

        mutating func markRecentlyUsed(_ index: Int) {
            guard index != self.newest else {
                return
            }
            self.unlink(index)
            self.linkNewest(index)
        }

        mutating func unlink(_ index: Int) {
            let (older, newer) = (self.entries[index].older, self.entries[index].newer)
            if let older {
                self.entries[older].newer = newer
            } else {
                self.oldest = newer
            }
            if let newer {
                self.entries[newer].older = older
            } else {
                self.newest = older
            }
        }

        mutating func linkNewest(_ index: Int) {
            self.entries[index].older = self.newest
            self.entries[index].newer = nil
            if let newest {
                self.entries[newest].newer = index
            } else {
                self.oldest = index
            }
            self.newest = index
        }
    }

    private let base: Base
    private let maximumEntryCount: Int
    private let maximumSourceByteCount: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Creates a cache for a highlighter with a fixed configuration.
    /// - Parameters:
    ///   - base: The highlighter whose results are cached.
    ///   - maximumEntryCount: Maximum retained results. Zero disables caching.
    ///   - maximumSourceByteCount: Maximum combined UTF-8 byte count of a code
    ///     block and its language for admission. Larger inputs bypass the cache.
    ///     This is an input-size limit, not a measurement of highlighted text memory.
    public init(
        _ base: Base,
        maximumEntryCount: Int = 64,
        maximumSourceByteCount: Int = 65536
    ) {
        self.base = base
        self.maximumEntryCount = max(0, maximumEntryCount)
        self.maximumSourceByteCount = max(0, maximumSourceByteCount)
    }

    public func highlightCode(_ code: String, language: String?) -> Text {
        let languageByteCount = language?.utf8.count ?? 0
        guard self.maximumEntryCount > 0,
              languageByteCount <= self.maximumSourceByteCount,
              code.utf8.count <= self.maximumSourceByteCount - languageByteCount else {
            return self.base.highlightCode(code, language: language)
        }

        // Hash the code before taking the lock; lookups inside it reuse this value.
        let key = Key(code: code, language: language)
        if let cached = self.state.withLock({ $0.text(for: key) }) {
            return cached
        }

        let result = self.base.highlightCode(code, language: language)
        return self.state.withLock { state in
            if let cached = state.text(for: key) {
                return cached
            }
            let index: Int
            if state.entries.count == self.maximumEntryCount, let oldest = state.oldest {
                // Reuse the least recently used slot.
                index = oldest
                state.indices.removeValue(forKey: state.entries[index].key)
                state.entries[index].key = key
                state.entries[index].text = result
                state.markRecentlyUsed(index)
            } else {
                index = state.entries.count
                state.entries.append(Entry(key: key, text: result))
                state.linkNewest(index)
            }
            state.indices[key] = index
            return result
        }
    }
}

/// A cache key that hashes its code once while still comparing the full inputs.
struct CodeSyntaxHighlighterCacheKey: Hashable, Sendable {
    let code: String
    let language: String?
    let precomputedHash: Int

    init(code: String, language: String?) {
        var hasher = Hasher()
        hasher.combine(code)
        hasher.combine(language)
        self.init(code: code, language: language, precomputedHash: hasher.finalize())
    }

    init(code: String, language: String?, precomputedHash: Int) {
        self.code = code
        self.language = language
        self.precomputedHash = precomputedHash
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.precomputedHash)
    }
}

public extension CodeSyntaxHighlighter {
    /// Caches repeated code and language pairs for this highlighter's configuration.
    ///
    /// Store the returned wrapper outside `body` so it survives view updates.
    /// Recreate it whenever configuration affecting highlighting changes. Copies of
    /// the wrapper share the same cache. Dynamic highlighters should remain uncached.
    /// See ``CachedCodeSyntaxHighlighter`` for admission and eviction behavior.
    func cached(
        maximumEntryCount: Int = 64,
        maximumSourceByteCount: Int = 65536
    ) -> CachedCodeSyntaxHighlighter<Self> {
        CachedCodeSyntaxHighlighter(
            self,
            maximumEntryCount: maximumEntryCount,
            maximumSourceByteCount: maximumSourceByteCount
        )
    }
}
