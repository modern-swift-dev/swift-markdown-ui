import SwiftUI

extension MarkdownContent {
    func blocks(matching colorScheme: ColorScheme) -> [BlockNode] {
        self.blocks(matching: colorScheme, conditionalImageBlockIndices: self.colorSchemeImageBlockIndices)
    }

    func blocks(matching colorScheme: ColorScheme, conditionalImageBlockIndices indices: [Int]) -> [BlockNode] {
        guard !indices.isEmpty else {
            return self.blocks
        }
        var result = self.blocks
        for index in indices {
            if let changed = self.blocks[index].filteringImagesIfChanged(matching: colorScheme) {
                result[index] = changed
            }
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
        let blocks = Array(self)
        return blocks.updatingChangedElements { $0.filteringImagesIfChanged(matching: colorScheme) } ?? blocks
    }
}

private extension BlockNode {
    /// `nil` means the original node and all its array storage can be retained.
    func filteringImagesIfChanged(matching colorScheme: ColorScheme) -> BlockNode? {
        switch self {
            case let .blockquote(children):
                children.updatingChangedElements {
                    $0.filteringImagesIfChanged(matching: colorScheme)
                }.map { .blockquote(children: $0) }
            case let .bulletedList(isTight, items):
                items.updatingChangedElements { item in
                    item.children.updatingChangedElements {
                        $0.filteringImagesIfChanged(matching: colorScheme)
                    }.map { RawListItem(children: $0, isCompleted: item.isCompleted) }
                }.map { .bulletedList(isTight: isTight, items: $0) }
            case let .numberedList(isTight, start, items):
                items.updatingChangedElements { item in
                    item.children.updatingChangedElements {
                        $0.filteringImagesIfChanged(matching: colorScheme)
                    }.map { RawListItem(children: $0, isCompleted: item.isCompleted) }
                }.map { .numberedList(isTight: isTight, start: start, items: $0) }
            case let .taskList(isTight, items):
                items.updatingChangedElements { item in
                    item.children.updatingChangedElements {
                        $0.filteringImagesIfChanged(matching: colorScheme)
                    }.map { RawTaskListItem(isCompleted: item.isCompleted, children: $0) }
                }.map { .taskList(isTight: isTight, items: $0) }
            case let .paragraph(content):
                content.filteringImagesIfChanged(matching: colorScheme)
                    .map { .paragraph(content: $0) }
            case let .heading(level, content):
                content.filteringImagesIfChanged(matching: colorScheme)
                    .map { .heading(level: level, content: $0) }
            case let .table(columnAlignments, rows):
                rows.updatingChangedElements { row in
                    row.cells.updatingChangedElements { cell in
                        cell.content.filteringImagesIfChanged(matching: colorScheme)
                            .map { RawTableCell(content: $0) }
                    }.map { RawTableRow(cells: $0) }
                }.map { .table(columnAlignments: columnAlignments, rows: $0) }
            case .codeBlock,
                 .htmlBlock,
                 .thematicBreak:
                nil
        }
    }
}

private extension Array {
    /// Copy only when a descendant supplies a replacement. `nil` denotes no changes.
    func updatingChangedElements(_ transform: (Element) -> Element?) -> Self? {
        var result = self
        var changed = false
        for index in self.indices {
            if let replacement = transform(self[index]) {
                result[index] = replacement
                changed = true
            }
        }
        return changed ? result : nil
    }
}

private extension [InlineNode] {
    func filteringImagesIfChanged(matching colorScheme: ColorScheme) -> Self? {
        var result: Self?
        for index in self.indices {
            let inline = self[index]
            if case let .image(source, _) = inline,
               source.contains("#"),
               let url = URL(string: source),
               !url.matchesColorScheme(colorScheme) {
                if result == nil {
                    result = Array(self[..<index])
                }
                continue
            }
            if let children = inline.children.filteringImagesIfChanged(matching: colorScheme) {
                var replacement = inline
                replacement.children = children
                if result == nil {
                    result = Array(self[..<index])
                }
                result?.append(replacement)
            } else {
                result?.append(inline)
            }
        }
        return result
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
