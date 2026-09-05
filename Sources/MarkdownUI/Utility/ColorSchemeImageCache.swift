import SwiftUI

/// Retains one conditional-image variant for one mounted Markdown view.
/// Like the parsing cache, synchronous memoization must not trigger observation.
@MainActor final class ColorSchemeImageCache {
    private var last: (content: MarkdownContent, colorScheme: ColorScheme, blocks: [BlockNode])?
    private let filter: (MarkdownContent, ColorScheme, [Int]) -> [BlockNode]

    init(filter: @escaping (MarkdownContent, ColorScheme, [Int]) -> [BlockNode] = {
        $0.blocks(matching: $1, conditionalImageBlockIndices: $2)
    }) {
        self.filter = filter
    }

    func blocks(for content: MarkdownContent, matching colorScheme: ColorScheme) -> [BlockNode] {
        if let last = self.last, last.colorScheme == colorScheme, last.content == content {
            return last.blocks
        }
        // Evict the prior variant before constructing another, including when the
        // new content has no conditional images and needs no cached result.
        self.last = nil
        let indices = content.colorSchemeImageBlockIndices
        guard !indices.isEmpty else {
            return content.blocks
        }
        let blocks = self.filter(content, colorScheme, indices)
        self.last = (content, colorScheme, blocks)
        return blocks
    }
}
