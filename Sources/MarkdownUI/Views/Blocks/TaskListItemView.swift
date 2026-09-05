import SwiftUI

struct TaskListItemView: View {
    @Environment(\.theme.listItem) private var listItem

    private let item: RawTaskListItem

    init(item: RawTaskListItem) {
        self.item = item
    }

    var body: some View {
        self.listItem.makeBody(
            configuration: .init(
                label: .init(TaskListItemLabel(item: self.item)),
                content: .init(blocks: item.children)
            )
        )
    }

}

struct TaskListItemLabel: View {
    @Environment(\.theme.taskListMarker) private var taskListMarker

    let item: RawTaskListItem

    var body: some View {
        Label {
            BlockSequence(self.item.children)
        } icon: {
            self.taskListMarker.makeBody(configuration: .init(isCompleted: self.item.isCompleted))
                .textStyleFont()
                .accessibilityLabel(self.item.isCompleted ? "Completed task" : "Incomplete task")
        }
        .accessibilityValue(self.item.isCompleted ? "Completed" : "Incomplete")
    }
}
