import Foundation

/// Parses successive versions of one Markdown source, reparsing only the tail that changed.
///
/// Streamed sources grow at the end, so reparsing the whole document for every update is
/// quadratic over the stream. When the new source keeps the previous one up to the start of a
/// top-level block, this parser reuses the blocks before it and parses only the rest.
///
/// It only splits where cmark has no block left open: the preceding block must be a paragraph,
/// heading, or thematic break, followed by a blank line. Neither source may contain anything
/// that could be a link reference definition, since those resolve links across the whole
/// document. Everything else falls back to a full parse, so the result always equals
/// `MarkdownContent(source)`.
struct IncrementalMarkdownParser {
    private var source = ""
    private var blocks: [BlockNode] = []
    /// Empty whenever the previous source cannot be reused.
    private var spans: [TopLevelBlockSpan] = []
    private var colorSchemeImageBlockIndices: [Int] = []

    /// The number of blocks the last call to ``parse(_:)`` reused from the previous source.
    private(set) var reusedBlockCount = 0

    mutating func parse(_ source: String) -> MarkdownContent {
        var source = source
        guard let split = source.withUTF8({ self.split(for: $0) }) else {
            self = .init()
            return self.parseFully(source)
        }

        // The split follows a line ending, so it is also a character boundary.
        let tail = String(source[source.utf8.index(source.startIndex, offsetBy: split.offset)...])
        let parsedTail = [BlockNode].parseTopLevelBlocks(markdown: tail)
        let tailImageIndices = parsedTail.blocks.indices.filter { parsedTail.blocks[$0].containsColorSchemeImages }

        self.source = source
        self.blocks = Array(self.blocks[..<split.blockIndex]) + parsedTail.blocks
        self.spans = Array(self.spans[..<split.blockIndex]) + parsedTail.spans.map { $0.shifted(by: split.offset) }
        self.colorSchemeImageBlockIndices = self.colorSchemeImageBlockIndices.filter { $0 < split.blockIndex }
            + tailImageIndices.map { $0 + split.blockIndex }
        self.reusedBlockCount = split.blockIndex
        return MarkdownContent(blocks: self.blocks, colorSchemeImageBlockIndices: self.colorSchemeImageBlockIndices)
    }

    private mutating func parseFully(_ source: String) -> MarkdownContent {
        let parsed = [BlockNode].parseTopLevelBlocks(markdown: source)
        let content = MarkdownContent(blocks: parsed.blocks)
        var source = source
        if source.withUTF8({ !Self.mayContainReferenceDefinition($0[...]) }) {
            self.source = source
            self.blocks = parsed.blocks
            self.spans = parsed.spans
            self.colorSchemeImageBlockIndices = content.colorSchemeImageBlockIndices
        }
        return content
    }

    /// Finds the last top-level block before which the new source can be reparsed.
    private func split(for newBytes: UnsafeBufferPointer<UInt8>) -> (blockIndex: Int, offset: Int)? {
        guard self.spans.count > 1 else {
            return nil
        }
        var oldSource = self.source
        return oldSource.withUTF8 { oldBytes -> (blockIndex: Int, offset: Int)? in
            let commonPrefixLength = Self.commonPrefixLength(oldBytes, newBytes)
            for index in self.spans.indices.dropFirst().reversed() {
                let predecessor = self.spans[index - 1]
                guard let start = self.spans[index].start, start <= commonPrefixLength,
                      predecessor.closesAtBlankLine, let end = predecessor.end, end < start,
                      Self.lineBeforeIsBlank(start, in: oldBytes) else {
                    continue
                }
                let tail = newBytes[start...]
                // A line feed after the shared carriage return would join its line ending,
                // and cmark only skips a byte order mark at the start of a document.
                guard !(oldBytes[start - 1] == 0x0D && tail.first == 0x0A),
                      !tail.starts(with: [0xEF, 0xBB, 0xBF]),
                      !Self.mayContainReferenceDefinition(tail) else {
                    return nil
                }
                return (index, start)
            }
            return nil
        }
    }

    private static func commonPrefixLength(_ lhs: UnsafeBufferPointer<UInt8>, _ rhs: UnsafeBufferPointer<UInt8>) -> Int {
        let count = min(lhs.count, rhs.count)
        if let lhsBase = lhs.baseAddress, let rhsBase = rhs.baseAddress, memcmp(lhsBase, rhsBase, count) == 0 {
            return count
        }
        var index = 0
        while index < count, lhs[index] == rhs[index] {
            index += 1
        }
        return index
    }

    /// Whether the line that ends right before `offset` contains only spaces and tabs.
    private static func lineBeforeIsBlank(_ offset: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard offset > 0, offset <= bytes.count else {
            return false
        }
        var index = offset - 1
        if bytes[index] == 0x0A, index > 0, bytes[index - 1] == 0x0D {
            index -= 1
        }
        guard bytes[index] == 0x0A || bytes[index] == 0x0D else {
            return false
        }
        while index > 0, bytes[index - 1] == 0x20 || bytes[index - 1] == 0x09 {
            index -= 1
        }
        return index == 0 || bytes[index - 1] == 0x0A || bytes[index - 1] == 0x0D
    }

    /// Every link reference definition contains a closing bracket followed by a colon.
    private static func mayContainReferenceDefinition(_ bytes: Slice<UnsafeBufferPointer<UInt8>>) -> Bool {
        var previous: UInt8 = 0
        for byte in bytes {
            if byte == 0x3A, previous == 0x5D {
                return true
            }
            previous = byte
        }
        return false
    }
}
