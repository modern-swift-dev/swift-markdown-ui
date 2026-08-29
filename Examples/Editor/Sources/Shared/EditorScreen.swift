import MarkdownUIEditor
import SwiftUI

@MainActor struct EditorScreen: View {
    @State private var markdown = """
    # Planning a release

    This draft keeps the **editor**, _formatting controls_, and `Markdown` source in one place.

    ## Lists

    1. Draft the release notes
    2. Review the changes

    - Build the example apps
    - Run the snapshot tests

    ## Checklist

    - [x] Write the first draft
    - [ ] Review [the editing guide](https://github.com/modern-swift-dev/swift-markdown-ui)
    - [ ] Ship the example

    > Small edits should feel immediate, even in a longer note.

    ```swift
    let editor = MarkdownEditor(markdown: $markdown)
    ```

    | Area | Status |
    | --- | --- |
    | Editor | Ready |
    | Theme | Selectable |
    """
    @State private var theme = EditorTheme.basic
    @State private var editorTheme = MarkdownEditorTheme.basic

    var body: some View {
        NavigationStack {
            MarkdownEditor(markdown: $markdown)
                .markdownEditorTheme(editorTheme)
                .onChange(of: theme) { editorTheme = $0.value }
                .markdownEditorShowsFormattingToolbar(true)
                .navigationTitle("Markdown editor")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Picker("Theme", selection: $theme) {
                            ForEach(EditorTheme.allCases) { theme in
                                Text(theme.title).tag(theme)
                            }
                        }
                    }
                }
        }
    }
}

private enum EditorTheme: String, CaseIterable, Identifiable {
    case basic
    case gitHub
    case docC

    var id: Self {
        self
    }

    var title: String {
        switch self {
            case .basic:
                "Basic"
            case .gitHub:
                "GitHub"
            case .docC:
                "DocC"
        }
    }

    @MainActor var value: MarkdownEditorTheme {
        switch self {
            case .basic:
                .basic
            case .gitHub:
                .gitHub
            case .docC:
                .docC
        }
    }
}
