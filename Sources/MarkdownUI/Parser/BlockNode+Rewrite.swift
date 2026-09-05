import Foundation

extension Sequence<BlockNode> {
    func rewrite(_ r: (BlockNode) throws -> [BlockNode]) rethrows -> [BlockNode] {
        try self.flatMap { try $0.rewrite(r) }
    }

    func rewrite(_ r: (InlineNode) throws -> [InlineNode]) rethrows -> [BlockNode] {
        try self.flatMap { try $0.rewrite(r) }
    }
}

extension BlockNode {
    func rewrite(_ r: (BlockNode) throws -> [BlockNode]) rethrows -> [BlockNode] {
        switch self {
            case let .blockquote(children):
                try r(.blockquote(children: children.rewrite(r)))
            case let .bulletedList(isTight, items):
                try r(
                    .bulletedList(
                        isTight: isTight,
                        items: try items.map {
                            RawListItem(children: try $0.children.rewrite(r), isCompleted: $0.isCompleted)
                        }
                    )
                )
            case let .numberedList(isTight, start, items):
                try r(
                    .numberedList(
                        isTight: isTight,
                        start: start,
                        items: try items.map {
                            RawListItem(children: try $0.children.rewrite(r), isCompleted: $0.isCompleted)
                        }
                    )
                )
            case let .taskList(isTight, items):
                try r(
                    .taskList(
                        isTight: isTight,
                        items: try items.map {
                            RawTaskListItem(isCompleted: $0.isCompleted, children: try $0.children.rewrite(r))
                        }
                    )
                )
            default:
                try r(self)
        }
    }

    func rewrite(_ r: (InlineNode) throws -> [InlineNode]) rethrows -> [BlockNode] {
        switch self {
            case let .blockquote(children):
                [.blockquote(children: try children.rewrite(r))]
            case let .bulletedList(isTight, items):
                [
                    .bulletedList(
                        isTight: isTight,
                        items: try items.map {
                            RawListItem(children: try $0.children.rewrite(r), isCompleted: $0.isCompleted)
                        }
                    )
                ]
            case let .numberedList(isTight, start, items):
                [
                    .numberedList(
                        isTight: isTight,
                        start: start,
                        items: try items.map {
                            RawListItem(children: try $0.children.rewrite(r), isCompleted: $0.isCompleted)
                        }
                    )
                ]
            case let .taskList(isTight, items):
                [
                    .taskList(
                        isTight: isTight,
                        items: try items.map {
                            RawTaskListItem(isCompleted: $0.isCompleted, children: try $0.children.rewrite(r))
                        }
                    )
                ]
            case let .paragraph(content):
                [.paragraph(content: try content.rewrite(r))]
            case let .heading(level, content):
                [.heading(level: level, content: try content.rewrite(r))]
            case let .table(columnAlignments, rows):
                [
                    .table(
                        columnAlignments: columnAlignments,
                        rows: try rows.map {
                            RawTableRow(
                                cells: try $0.cells.map {
                                    RawTableCell(content: try $0.content.rewrite(r))
                                }
                            )
                        }
                    )
                ]
            default:
                [self]
        }
    }
}
