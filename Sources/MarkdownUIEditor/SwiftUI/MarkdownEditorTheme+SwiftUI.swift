#if canImport(SwiftUI) && (os(iOS) || os(macOS) || targetEnvironment(macCatalyst))
import SwiftUI

private struct MarkdownEditorThemeKey: EnvironmentKey {
    static let defaultValue: MarkdownEditorTheme = MainActor.assumeIsolated { .basic }
}

private struct MarkdownEditorShowsFormattingToolbarKey: EnvironmentKey {
    static let defaultValue = true
}

private struct MarkdownEditorImageProviderKey: EnvironmentKey {
    static let defaultValue: (any MarkdownEditorImageProvider)? = nil
}

extension EnvironmentValues {
    /// The theme inherited by `MarkdownEditor` descendants.
    var markdownEditorTheme: MarkdownEditorTheme {
        get { self[MarkdownEditorThemeKey.self] }
        set { self[MarkdownEditorThemeKey.self] = newValue }
    }

    /// Whether `MarkdownEditor` descendants show the standard formatting toolbar.
    var markdownEditorShowsFormattingToolbar: Bool {
        get { self[MarkdownEditorShowsFormattingToolbarKey.self] }
        set { self[MarkdownEditorShowsFormattingToolbarKey.self] = newValue }
    }

    /// The image provider inherited by `MarkdownEditor` descendants.
    var markdownEditorImageProvider: (any MarkdownEditorImageProvider)? {
        get { self[MarkdownEditorImageProviderKey.self] }
        set { self[MarkdownEditorImageProviderKey.self] = newValue }
    }
}

public extension View {
    /// Sets the theme used by descendant Markdown editors.
    func markdownEditorTheme(_ theme: MarkdownEditorTheme) -> some View {
        environment(\.markdownEditorTheme, theme)
    }

    /// Shows or hides the editor's standard SwiftUI formatting controls.
    func markdownEditorShowsFormattingToolbar(_ shows: Bool) -> some View {
        environment(\.markdownEditorShowsFormattingToolbar, shows)
    }

    /// Sets the URL image provider used by descendant Markdown editors.
    func markdownEditorImageProvider(_ provider: (any MarkdownEditorImageProvider)?) -> some View {
        environment(\.markdownEditorImageProvider, provider)
    }
}
#endif
