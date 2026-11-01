#if canImport(SwiftUI) && (os(iOS) || os(macOS) || targetEnvironment(macCatalyst))
    import SwiftUI

    private struct MarkdownEditorThemeKey: EnvironmentKey {
        static let defaultValue: MarkdownEditorTheme = MainActor.assumeIsolated { .basic }
    }

    private struct MarkdownEditorShowsFormattingToolbarKey: EnvironmentKey {
        static let defaultValue = true
    }

    private struct MarkdownEditorIsEditableKey: EnvironmentKey {
        static let defaultValue = true
    }

    private struct MarkdownEditorConvertsMarkdownShortcutsKey: EnvironmentKey {
        static let defaultValue = false
    }

    private struct MarkdownEditorImageProviderKey: EnvironmentKey {
        static let defaultValue: (any MarkdownEditorImageProvider)? = nil
    }

    private struct MarkdownEditorImageLoadingPolicyKey: EnvironmentKey {
        static let defaultValue = MarkdownEditorImageLoadingPolicy.allowAll
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

        /// Whether `MarkdownEditor` descendants accept edits.
        var markdownEditorIsEditable: Bool {
            get { self[MarkdownEditorIsEditableKey.self] }
            set { self[MarkdownEditorIsEditableKey.self] = newValue }
        }

        /// Whether `MarkdownEditor` descendants convert Markdown block markers while typing.
        var markdownEditorConvertsMarkdownShortcuts: Bool {
            get { self[MarkdownEditorConvertsMarkdownShortcutsKey.self] }
            set { self[MarkdownEditorConvertsMarkdownShortcutsKey.self] = newValue }
        }

        /// The image provider inherited by `MarkdownEditor` descendants.
        var markdownEditorImageProvider: (any MarkdownEditorImageProvider)? {
            get { self[MarkdownEditorImageProviderKey.self] }
            set { self[MarkdownEditorImageProviderKey.self] = newValue }
        }

        /// The image loading policy inherited by `MarkdownEditor` descendants.
        var markdownEditorImageLoadingPolicy: MarkdownEditorImageLoadingPolicy {
            get { self[MarkdownEditorImageLoadingPolicyKey.self] }
            set { self[MarkdownEditorImageLoadingPolicyKey.self] = newValue }
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

        /// Makes descendant Markdown editors editable or read-only.
        ///
        /// A read-only editor still lets people select and copy text and open links.
        func markdownEditorIsEditable(_ isEditable: Bool) -> some View {
            environment(\.markdownEditorIsEditable, isEditable)
        }

        /// Turns on or off converting Markdown block markers while typing in descendant editors.
        ///
        /// When on, typing a marker at the start of a paragraph converts it: `#` … `######`
        /// then space to a heading, `-`, `*` or `+` then space to a bulleted list, a number
        /// then `.` or `)` then space to a numbered list, `[ ] ` or `[x] ` to a task, `> ` to a
        /// quote, and three backticks with an optional info string then Return to a code block.
        /// Undo right after a conversion restores the typed characters. Off by default.
        func markdownEditorConvertsMarkdownShortcuts(_ converts: Bool) -> some View {
            environment(\.markdownEditorConvertsMarkdownShortcuts, converts)
        }

        /// Sets the URL image provider used by descendant Markdown editors.
        func markdownEditorImageProvider(_ provider: (any MarkdownEditorImageProvider)?) -> some View {
            environment(\.markdownEditorImageProvider, provider)
        }

        /// Sets the policy that decides which URLs descendant Markdown editors may load images from.
        ///
        /// The policy applies whichever image provider the editor uses. Blocked images are never
        /// requested and show their alternative text instead. Set the policy before the editor appears;
        /// a change applies to images the editor displays afterwards.
        /// - Parameter policy: The image loading policy to set. The default is
        ///   ``MarkdownEditorImageLoadingPolicy/allowAll``.
        func markdownEditorImageLoadingPolicy(_ policy: MarkdownEditorImageLoadingPolicy) -> some View {
            environment(\.markdownEditorImageLoadingPolicy, policy)
        }
    }
#endif
