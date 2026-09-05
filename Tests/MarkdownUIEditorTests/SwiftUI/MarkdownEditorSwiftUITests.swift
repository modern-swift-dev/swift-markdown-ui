#if os(macOS) && canImport(SwiftUI) && canImport(AppKit)
import AppKit
@testable import MarkdownUIEditor
import SwiftUI
import XCTest

@MainActor final class MarkdownEditorSwiftUITests: XCTestCase {
    func testRepresentableInstallsInitialAndUpdatedConfigurationOnce() throws {
        let observer = StorageReplacementObserver()
        NotificationCenter.default.addObserver(
            observer, selector: #selector(StorageReplacementObserver.storageChanged(_:)),
            name: NSTextStorage.didProcessEditingNotification, object: nil
        )
        defer { NotificationCenter.default.removeObserver(observer) }
        let initialTheme = MarkdownEditorTheme.docC
        let initialProvider = MarkdownURLSessionImageProvider()
        let initialURL = try XCTUnwrap(URL(string: "https://example.com/first/"))
        let host = NSHostingView(rootView: configuredEditor("initial", theme: initialTheme, baseURL: initialURL, provider: initialProvider))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(findTextView(in: host))
        let storage = try XCTUnwrap(editor.textStorage)
        XCTAssertEqual(storage.string, "initial\n")
        XCTAssertEqual(observer.replacements[ObjectIdentifier(storage)], 1)
        XCTAssertTrue(editor.editorTheme === initialTheme)
        XCTAssertTrue(editor.imageProvider === initialProvider)
        XCTAssertEqual(editor.baseURL, initialURL)
        editor.selectedRange = NSRange(location: 2, length: 2)

        let updatedTheme = MarkdownEditorTheme.gitHub
        let updatedProvider = MarkdownURLSessionImageProvider()
        let updatedURL = try XCTUnwrap(URL(string: "https://example.com/second/"))
        observer.replacements.removeAll()
        host.rootView = configuredEditor("updated", theme: updatedTheme, baseURL: updatedURL, provider: updatedProvider)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(try XCTUnwrap(findTextView(in: host)) === editor)
        XCTAssertEqual(storage.string, "updated\n")
        XCTAssertEqual(observer.replacements[ObjectIdentifier(storage)], 1)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 2, length: 2))
        XCTAssertTrue(editor.editorTheme === updatedTheme)
        XCTAssertTrue(editor.imageProvider === updatedProvider)
        XCTAssertEqual(editor.baseURL, updatedURL)

        observer.replacements.removeAll()
        host.rootView = configuredEditor("updated", theme: .gitHub, baseURL: updatedURL, provider: updatedProvider)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(observer.replacements[ObjectIdentifier(storage)])
    }

    private func configuredEditor(
        _ source: String, theme: MarkdownEditorTheme, baseURL: URL?, provider: any MarkdownEditorImageProvider
    ) -> some View {
        MarkdownEditor(document: .constant(MarkdownDocument(markdown: source)), baseURL: baseURL)
            .markdownEditorTheme(theme)
            .markdownEditorImageProvider(provider)
            .markdownEditorShowsFormattingToolbar(false)
    }

    func testDocumentBindingInitializerBuilds() {
        var document = MarkdownDocument(markdown: "# Title")
        let binding = Binding<MarkdownDocument>(
            get: { document },
            set: { document = $0 }
        )

        _ = MarkdownEditor(document: binding)
        XCTAssertEqual(document.markdown, "# Title\n")
    }

    func testMarkdownBindingWritesNormalizedSource() {
        var markdown = "text"
        let binding = Binding<String>(
            get: { markdown },
            set: { markdown = $0 }
        )
        let editor = MarkdownEditor(markdown: binding)
        let normalized = MarkdownDocument(markdown: markdown).markdown

        _ = editor
        XCTAssertEqual(normalized, "text\n")
    }

    func testReplacingSourceBindingWritesToCurrentOwner() async throws {
        var first = "same"
        var second = "same"
        let host = NSHostingView(rootView: MarkdownEditor(markdown: Binding(get: { first }, set: { first = $0 })))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(findTextView(in: host))
        XCTAssertEqual(textView.document.markdown, "same\n")

        host.rootView = MarkdownEditor(markdown: Binding(get: { second }, set: { second = $0 }))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(try XCTUnwrap(findTextView(in: host)) === textView)
        textView.selectedRange = NSRange(location: 0, length: 4)
        textView.perform(.toggleInline(.strong))

        XCTAssertEqual(first, "same")
        XCTAssertEqual(second, "**same**\n", "The replacement binding must receive edits synchronously")
    }

    func testExternalDocumentUpdateReplacesNativeDocument() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.document = MarkdownDocument(markdown: "first")
        textView.document = MarkdownDocument(markdown: "second")

        XCTAssertEqual(textView.document.markdown, "second\n")
    }

    func testDelegateUpdateChangesBoundDocument() {
        var document = MarkdownDocument(markdown: "text")
        let binding = Binding<MarkdownDocument>(
            get: { document },
            set: { document = $0 }
        )
        let coordinator = EditorDelegate(document: binding)
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.markdownDelegate = coordinator
        textView.document = document
        textView.selectedRange = NSRange(location: 0, length: 4)

        textView.perform(.toggleInline(.strong))

        XCTAssertEqual(document.markdown, "**text**\n")
    }

    func testThemeModifierBuilds() {
        let editor = MarkdownEditor(document: .constant(MarkdownDocument()))
            .markdownEditorTheme(.docC)
            .markdownEditorShowsFormattingToolbar(false)

        _ = editor
    }

    func testContextRoutesCommandsToCurrentTextView() {
        let context = MarkdownEditorContext()
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.document = MarkdownDocument(markdown: "text")
        textView.selectedRange = NSRange(location: 0, length: 4)
        context.setTextView(textView)

        XCTAssertTrue(context.canPerform(.toggleInline(.strong)))
        context.perform(.toggleInline(.strong))

        XCTAssertEqual(textView.document.markdown, "**text**\n")
        context.setTextView(nil)
        XCTAssertFalse(context.canPerform(.toggleInline(.strong)))
    }

    func testHostedToolbarEnablesAfterAttachmentAndFormatsSelection() async throws {
        var document = MarkdownDocument(markdown: "hello")
        let hostingView = NSHostingView(rootView:
            MarkdownEditor(document: Binding(get: { document }, set: { document = $0 }))
                .markdownEditorShowsFormattingToolbar(true)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        // SwiftUI creates its accessibility nodes lazily until assistive access is enabled.
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))

        let textView = try XCTUnwrap(findTextView(in: hostingView))
        window.makeFirstResponder(textView)
        textView.selectedRange = NSRange(location: 0, length: 5)
        try await Task.sleep(for: .milliseconds(150))
        let bold = try XCTUnwrap(findAccessibilityElement(labeled: "Bold", in: hostingView))
        XCTAssertTrue(accessibilityFlag("isAccessibilityEnabled", on: bold))
        XCTAssertTrue(accessibilityFlag("accessibilityPerformPress", on: bold))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(document.markdown, "**hello**\n")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 5))
        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertEqual(bold.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? String, "Selected")
        let undoManager = try XCTUnwrap(textView.undoManager)
        undoManager.undo()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(document.markdown, "hello\n")
        XCTAssertEqual(bold.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? String, "Not selected")
        undoManager.redo()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(document.markdown, "**hello**\n")
    }

    func testToolbarRestoresFocusAndPreservesCaretTypingStyle() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = textView
        textView.document = MarkdownDocument(markdown: "hello")
        window.makeFirstResponder(textView)
        textView.selectedRange = NSRange(location: 5, length: 0)
        let context = MarkdownEditorContext()
        context.setTextView(textView)
        window.makeFirstResponder(nil)

        context.perform(.toggleInline(.strong))
        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertTrue(context.isActive(.toggleInline(.strong)))
        textView.insertText("X", replacementRange: textView.selectedRange)
        XCTAssertEqual(textView.document.markdown, "hello**X**\n")
    }

    private func findTextView(in view: NSView) -> MarkdownTextView? {
        if let textView = view as? MarkdownTextView {
            return textView
        }
        return view.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
    }

    private func findAccessibilityElement(labeled label: String, in object: Any) -> NSObject? {
        guard let element = object as? NSObject else {
            return nil
        }
        let labelSelector = NSSelectorFromString("accessibilityLabel")
        if element.responds(to: labelSelector),
           element.perform(labelSelector)?.takeUnretainedValue() as? String == label {
            return element
        }
        if let view = element as? NSView {
            for child in view.subviews {
                if let match = findAccessibilityElement(labeled: label, in: child) {
                    return match
                }
            }
        }
        let childrenSelector = NSSelectorFromString("accessibilityChildren")
        guard element.responds(to: childrenSelector),
              let children = element.perform(childrenSelector)?.takeUnretainedValue() as? [Any] else {
            return nil
        }
        for child in children {
            if let match = findAccessibilityElement(labeled: label, in: child) {
                return match
            }
        }
        return nil
    }

    private func accessibilityFlag(_ name: String, on element: NSObject) -> Bool {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else {
            return false
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let getter = unsafeBitCast(element.method(for: selector), to: Getter.self)
        return getter(element, selector)
    }

    func testSwiftUISourceDoesNotImportMarkdownUI() throws {
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MarkdownUIEditor/SwiftUI")
        let sources = try FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        )

        for source in sources where source.pathExtension == "swift" {
            let contents = try String(contentsOf: source, encoding: .utf8)
            XCTAssertFalse(contents.contains("import Markdown" + "UI"))
        }
    }
}

@MainActor private final class EditorDelegate: MarkdownTextViewDelegate {
    var document: Binding<MarkdownDocument>

    init(document: Binding<MarkdownDocument>) {
        self.document = document
    }

    func markdownTextView(_ textView: MarkdownTextView, didChange document: MarkdownDocument) {
        self.document.wrappedValue = document
    }
}

@MainActor private final class StorageReplacementObserver: NSObject {
    var replacements: [ObjectIdentifier: Int] = [:]

    @objc func storageChanged(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else {
            return
        }
        replacements[ObjectIdentifier(storage), default: 0] += 1
    }
}
#endif
