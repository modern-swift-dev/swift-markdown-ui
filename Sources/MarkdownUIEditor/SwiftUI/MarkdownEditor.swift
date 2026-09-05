#if canImport(SwiftUI) && (os(iOS) || os(macOS) || targetEnvironment(macCatalyst))
import SwiftUI

/// A SwiftUI wrapper around the platform-native Markdown editor.
@MainActor public struct MarkdownEditor: View {
    /// The structured document binding that receives editor changes.
    private let document: Binding<MarkdownDocument>
    /// The base URL used to resolve relative image destinations.
    private let baseURL: URL?
    /// The focused command target for this editor instance.
    @StateObject private var editorContext = MarkdownEditorContext()
    @Environment(\.markdownEditorTheme) private var theme
    @Environment(\.markdownEditorShowsFormattingToolbar) private var showsFormattingToolbar
    @Environment(\.markdownEditorImageProvider) private var imageProvider

    /// Creates an editor for a structured Markdown document.
    public init(document: Binding<MarkdownDocument>, baseURL: URL? = nil) {
        self.document = document
        self.baseURL = baseURL
    }

    /// Creates an editor for Markdown source.
    ///
    /// The binding receives the editor's normalized Markdown after an edit.
    public init(markdown: Binding<String>, baseURL: URL? = nil) {
        self.document = Binding(
            get: { MarkdownDocument(markdown: markdown.wrappedValue) },
            set: { document in
                let normalized = document.markdown
                if markdown.wrappedValue != normalized {
                    markdown.wrappedValue = normalized
                }
            }
        )
        self.baseURL = baseURL
    }

    /// The native text view and, when enabled, its SwiftUI formatting controls.
    public var body: some View {
        VStack(spacing: 0) {
            PlatformMarkdownEditor(
                document: document,
                theme: theme,
                baseURL: baseURL,
                imageProvider: imageProvider,
                editorContext: editorContext
            )

            if showsFormattingToolbar {
                MarkdownEditorFormattingToolbar(context: editorContext)
            }
        }
        .focusedValue(\.markdownEditorContext, editorContext)
    }
}

struct MarkdownEditorFormattingToolbar: View {
    @ObservedObject var context: MarkdownEditorContext
    @State private var linkDestination = ""
    @State private var imageSource = ""
    @State private var imageAlt = ""
    @State private var showsLinkEditor = false
    @State private var showsImageEditor = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                commandButton("Bold", symbol: "bold", command: .toggleInline(.strong))
                commandButton("Italic", symbol: "italic", command: .toggleInline(.emphasis))
                commandButton("Strikethrough", symbol: "strikethrough", command: .toggleInline(.strikethrough))
                commandButton("Inline code", symbol: "chevron.left.forwardslash.chevron.right", command: .toggleInline(.code))
                Menu {
                    commandItem("Paragraph", command: .convertBlock(.paragraph))
                    ForEach(MarkdownHeadingLevel.allCases, id: \.self) { level in
                        commandItem("Heading \(level.rawValue)", command: .convertBlock(.heading(level)))
                    }
                    commandItem("Quote", command: .convertBlock(.blockquote))
                    commandItem("Code block", command: .convertBlock(.code(info: nil)))
                    commandItem("Horizontal rule", command: .insertThematicBreak)
                } label: { Label("Paragraph style", systemImage: "textformat") }
                Menu {
                    commandItem("Bulleted list", command: .convertList(.unordered))
                    commandItem("Numbered list", command: .convertList(.ordered(start: 1)))
                    commandItem("Checklist", command: .convertList(.task))
                    commandItem("Toggle checkbox", command: .toggleTask)
                    Divider()
                    commandItem("Indent", command: .indent)
                    commandItem("Outdent", command: .outdent)
                } label: { Label("Lists", systemImage: "list.bullet") }
                Menu {
                    commandItem("Insert table", command: .insertTable(columns: 2, bodyRows: 2))
                    Divider()
                    commandItem("Add row", command: .insertTableRow)
                    commandItem("Delete row", command: .deleteTableRow)
                    commandItem("Move row up", command: .moveTableRow(.backward))
                    commandItem("Move row down", command: .moveTableRow(.forward))
                    Divider()
                    commandItem("Add column", command: .insertTableColumn)
                    commandItem("Delete column", command: .deleteTableColumn)
                    commandItem("Move column left", command: .moveTableColumn(.backward))
                    commandItem("Move column right", command: .moveTableColumn(.forward))
                    Divider()
                    commandItem("Align left", command: .setTableColumnAlignment(.left))
                    commandItem("Align center", command: .setTableColumnAlignment(.center))
                    commandItem("Align right", command: .setTableColumnAlignment(.right))
                } label: { Label("Table", systemImage: "tablecells") }
                Menu {
                    Button("Add or edit link") { showsLinkEditor = true }
                        .disabled(!context.canPerform(.setLink(destination: "https://", title: nil)))
                    commandItem("Remove link", command: .removeLink)
                    Button("Insert image") { showsImageEditor = true }
                        .disabled(!context.canPerform(.insertImage(source: "https://", title: nil, alt: "")))
                } label: { Label("Links and images", systemImage: "link") }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .padding(8)
        }
        .alert("Add or edit link", isPresented: $showsLinkEditor) {
            TextField("Link URL", text: $linkDestination)
            Button("Apply") {
                context.perform(.setLink(destination: linkDestination, title: nil))
                linkDestination = ""
            }.disabled(linkDestination.isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Insert image", isPresented: $showsImageEditor) {
            TextField("Image URL", text: $imageSource)
            TextField("Alternative text", text: $imageAlt)
            Button("Insert") {
                context.perform(.insertImage(source: imageSource, title: nil, alt: imageAlt))
                imageSource = ""
                imageAlt = ""
            }.disabled(imageSource.isEmpty)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func commandButton(_ title: String, symbol: String, command: MarkdownEditorCommand) -> some View {
        Button { context.perform(command) } label: { Label(title, systemImage: symbol) }
            .disabled(!context.canPerform(command))
            .tint(context.isActive(command) ? Color.accentColor : Color.secondary)
            .accessibilityLabel(title)
            .accessibilityValue(context.isActive(command) ? "Selected" : "Not selected")
            .help(title)
    }

    private func commandItem(_ title: String, command: MarkdownEditorCommand) -> some View {
        Button { context.perform(command) } label: {
            if context.isActive(command) {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .labelStyle(.titleAndIcon)
        .disabled(!context.canPerform(command))
    }
}

#if os(iOS) || targetEnvironment(macCatalyst)
private struct PlatformMarkdownEditor: UIViewRepresentable {
    /// The binding synchronized with the UIKit editor.
    let document: Binding<MarkdownDocument>
    /// Attributes applied by the projection.
    let theme: MarkdownEditorTheme
    /// URL used for relative image references.
    let baseURL: URL?
    /// Provider used by image attachments.
    let imageProvider: (any MarkdownEditorImageProvider)?
    /// Command target installed for the focused editor.
    let editorContext: MarkdownEditorContext

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, context: editorContext)
    }

    func makeUIView(context: Context) -> MarkdownTextView {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.markdownDelegate = context.coordinator
        textView.document = document.wrappedValue
        textView.editorTheme = theme
        textView.baseURL = baseURL
        textView.imageProvider = imageProvider
        context.coordinator.context.setTextView(textView)
        return textView
    }

    func updateUIView(_ textView: MarkdownTextView, context: Context) {
        context.coordinator.updateDocument(document, in: textView)
        textView.editorTheme = theme
        textView.baseURL = baseURL
        textView.imageProvider = imageProvider
        context.coordinator.context.setTextView(textView)
    }

    static func dismantleUIView(_ textView: MarkdownTextView, coordinator: Coordinator) {
        textView.markdownDelegate = nil
        coordinator.context.setTextView(nil)
    }

    @MainActor final class Coordinator: NSObject, MarkdownTextViewDelegate {
        /// The binding updated after native text edits.
        var document: Binding<MarkdownDocument>
        /// The command context bound to this native text view.
        let context: MarkdownEditorContext
        /// The value last read from the owner. Markdown source cannot retain
        /// empty editing paragraphs, so it need not equal the native document.
        private var lastBindingValue: MarkdownDocument

        init(document: Binding<MarkdownDocument>, context: MarkdownEditorContext) {
            self.document = document
            self.context = context
            self.lastBindingValue = document.wrappedValue
        }

        func updateDocument(_ binding: Binding<MarkdownDocument>, in textView: MarkdownTextView) {
            document = binding
            let incoming = binding.wrappedValue
            guard incoming != lastBindingValue else {
                return
            }
            lastBindingValue = incoming
            textView.editingSession.replaceDocumentFromBinding(incoming)
        }

        func markdownTextView(_ textView: MarkdownTextView, didChange document: MarkdownDocument) {
            if self.document.wrappedValue != document {
                self.document.wrappedValue = document
            }
            // Read back the binding's representation, which may normalize the
            // published document. Repeated view updates are not external edits.
            lastBindingValue = self.document.wrappedValue
            textView.editingSession.acknowledgeBindingDocument(lastBindingValue)
        }
    }
}

#elseif os(macOS)
private struct PlatformMarkdownEditor: NSViewRepresentable {
    /// The binding synchronized with the AppKit editor.
    let document: Binding<MarkdownDocument>
    /// Attributes applied by the projection.
    let theme: MarkdownEditorTheme
    /// URL used for relative image references.
    let baseURL: URL?
    /// Provider used by image attachments.
    let imageProvider: (any MarkdownEditorImageProvider)?
    /// Command target installed for the focused editor.
    let editorContext: MarkdownEditorContext

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, context: editorContext)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        textView.markdownDelegate = context.coordinator
        textView.document = document.wrappedValue
        textView.editorTheme = theme
        textView.baseURL = baseURL
        textView.imageProvider = imageProvider
        context.coordinator.context.setTextView(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else {
            return
        }
        context.coordinator.updateDocument(document, in: textView)
        textView.editorTheme = theme
        textView.baseURL = baseURL
        textView.imageProvider = imageProvider
        context.coordinator.context.setTextView(textView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        (scrollView.documentView as? MarkdownTextView)?.markdownDelegate = nil
        coordinator.context.setTextView(nil)
    }

    @MainActor final class Coordinator: NSObject, MarkdownTextViewDelegate {
        /// The binding updated after native text edits.
        var document: Binding<MarkdownDocument>
        /// The command context bound to this native text view.
        let context: MarkdownEditorContext
        /// The value last read from the owner. Markdown source cannot retain
        /// empty editing paragraphs, so it need not equal the native document.
        private var lastBindingValue: MarkdownDocument

        init(document: Binding<MarkdownDocument>, context: MarkdownEditorContext) {
            self.document = document
            self.context = context
            self.lastBindingValue = document.wrappedValue
        }

        func updateDocument(_ binding: Binding<MarkdownDocument>, in textView: MarkdownTextView) {
            document = binding
            let incoming = binding.wrappedValue
            guard incoming != lastBindingValue else {
                return
            }
            lastBindingValue = incoming
            textView.editingSession.replaceDocumentFromBinding(incoming)
        }

        func markdownTextView(_ textView: MarkdownTextView, didChange document: MarkdownDocument) {
            if self.document.wrappedValue != document {
                self.document.wrappedValue = document
            }
            // Read back the binding's representation, which may normalize the
            // published document. Repeated view updates are not external edits.
            lastBindingValue = self.document.wrappedValue
            textView.editingSession.acknowledgeBindingDocument(lastBindingValue)
        }
    }
}
#endif
#endif
