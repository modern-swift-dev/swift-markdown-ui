import SwiftUI

extension MarkdownContent {
    func blocks(matching colorScheme: ColorScheme) -> [BlockNode] {
        guard !self.colorSchemeImageBlockIndices.isEmpty else {
            return self.blocks
        }
        var result = self.blocks
        for index in self.colorSchemeImageBlockIndices {
            // Inline filtering preserves the top-level block, even if all its images disappear.
            result[index] = [self.blocks[index]].filterImagesMatching(colorScheme: colorScheme)[0]
        }
        return result
    }
}

extension BlockNode {
    var containsColorSchemeImages: Bool {
        switch self {
            case let .blockquote(children):
                children.contains(where: \.containsColorSchemeImages)
            case let .bulletedList(_, items),
                 let .numberedList(_, _, items):
                items.contains { $0.children.contains(where: \.containsColorSchemeImages) }
            case let .taskList(_, items):
                items.contains { $0.children.contains(where: \.containsColorSchemeImages) }
            case let .paragraph(content),
                 let .heading(_, content):
                content.contains(where: \.containsColorSchemeImages)
            case let .table(_, rows):
                rows.contains { $0.cells.contains { $0.content.contains(where: \.containsColorSchemeImages) } }
            case .codeBlock,
                 .htmlBlock,
                 .thematicBreak:
                false
        }
    }
}

private extension InlineNode {
    var containsColorSchemeImages: Bool {
        if case let .image(source, _) = self,
           source.contains("#"),
           let fragment = URL(string: source)?.fragment?.lowercased(),
           fragment == "gh-dark-mode-only" || fragment == "gh-light-mode-only" {
            return true
        }
        return self.children.contains(where: \.containsColorSchemeImages)
    }
}

extension Sequence<BlockNode> {
    func filterImagesMatching(colorScheme: ColorScheme) -> [BlockNode] {
        self.rewrite { inline in
            switch inline {
                case let .image(source, _):
                    guard let url = URL(string: source) else {
                        return [inline]
                    }
                    return url.matchesColorScheme(colorScheme) ? [inline] : []
                default:
                    return [inline]
            }
        }
    }
}

private extension URL {
    func matchesColorScheme(_ colorScheme: ColorScheme) -> Bool {
        guard let fragment = self.fragment?.lowercased() else {
            return true
        }

        switch colorScheme {
            case .light:
                return fragment != "gh-dark-mode-only"
            case .dark:
                return fragment != "gh-light-mode-only"
            @unknown default:
                return true
        }
    }
}
