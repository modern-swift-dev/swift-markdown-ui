import SwiftUI

extension BlockNode: View {
    var body: some View {
        switch self {
            case let .blockquote(children):
                BlockquoteView(children: children)
            case let .bulletedList(isTight, items):
                BulletedListView(isTight: isTight, items: items)
            case let .numberedList(isTight, start, items):
                NumberedListView(isTight: isTight, start: start, items: items)
            case let .taskList(isTight, items):
                TaskListView(isTight: isTight, items: items)
            case let .codeBlock(fenceInfo, content):
                CodeBlockView(fenceInfo: fenceInfo, content: content)
            case let .htmlBlock(content):
                ParagraphView(content: content)
            case let .paragraph(content):
                ParagraphView(content: content)
            case let .heading(level, content):
                HeadingView(level: level, content: content)
            case let .table(columnAlignments, rows):
                if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
                    TableView(columnAlignments: columnAlignments, rows: rows)
                }
            case .thematicBreak:
                ThematicBreakView()
        }
    }
}
