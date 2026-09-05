import os
import SwiftUI

/// A bounded cache of the text returned by another syntax highlighter.
///
/// Retain this wrapper across view updates so repeated code blocks reuse their
/// highlighted text. Its key contains the code and language. Use it only when the
/// wrapped highlighter produces the same result for those inputs, and create a
/// new wrapper when the highlighter's configuration (such as its theme) changes.
///
/// The cache evicts entries in insertion order. Entry and source-size limits bound
/// retained inputs and result count, rather than the exact memory used by `Text`.
/// Concurrent misses may invoke the wrapped highlighter more than once; cache
/// access is synchronized without holding a lock while calling user code.
public struct CachedCodeSyntaxHighlighter<Base: CodeSyntaxHighlighter>: CodeSyntaxHighlighter {
    private struct Key: Hashable {
        let code: String
        let language: String?
    }

    private struct State {
        var values: [Key: Text] = [:]
        var insertionOrder: [Key] = []
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

        let key = Key(code: code, language: language)
        if let cached = self.state.withLock({ $0.values[key] }) {
            return cached
        }

        let result = self.base.highlightCode(code, language: language)
        return self.state.withLock { state in
            if let cached = state.values[key] {
                return cached
            }
            if state.insertionOrder.count == self.maximumEntryCount {
                state.values.removeValue(forKey: state.insertionOrder.removeFirst())
            }
            state.insertionOrder.append(key)
            state.values[key] = result
            return result
        }
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
