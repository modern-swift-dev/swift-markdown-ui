import Foundation

/// A UTF-16 range in the native rich-text projection.
struct ProjectionUTF16Range: Hashable, Sendable {
    /// Offset from the beginning of the projection.
    var location: Int
    /// Number of UTF-16 code units in the range.
    var length: Int

    init(location: Int, length: Int) {
        precondition(location >= 0 && length >= 0)
        self.location = location
        self.length = length
    }

    init(_ range: NSRange) {
        self.init(location: range.location, length: range.length)
    }

    var upperBound: Int {
        location + length
    }

    var nsRange: NSRange {
        NSRange(location: location, length: length)
    }
}

/// A UTF-16 range in serialized Markdown source.
struct SourceUTF16Range: Hashable, Sendable {
    /// Offset from the beginning of the Markdown source.
    var location: Int
    /// Number of UTF-16 code units in the range.
    var length: Int

    init(location: Int, length: Int) {
        precondition(location >= 0 && length >= 0)
        self.location = location
        self.length = length
    }

    init(_ range: NSRange) {
        self.init(location: range.location, length: range.length)
    }

    var upperBound: Int {
        location + length
    }

    var nsRange: NSRange {
        NSRange(location: location, length: length)
    }
}
