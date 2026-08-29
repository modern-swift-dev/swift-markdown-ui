import Foundation
import UniformTypeIdentifiers

public extension UTType {
    /// GitHub Flavored Markdown carried as a UTF-8 string on the pasteboard.
    static let markdown = UTType(importedAs: "net.daringfireball.markdown")
}

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct MarkdownClipboardPayload: Hashable, Sendable {
    /// The Markdown source representation, when available.
    public var markdown: String?
    /// The plain-text fallback representation, when available.
    public var plainText: String?

    /// Creates a pasteboard payload from Markdown, plain text, or both.
    public init(markdown: String? = nil, plainText: String? = nil) {
        self.markdown = markdown
        self.plainText = plainText
    }

    /// The text an editor should insert. Markdown wins when both representations exist.
    public var preferredText: String? {
        markdown ?? plainText
    }

    /// Whether the payload contains a Markdown representation.
    public var prefersMarkdown: Bool {
        markdown != nil
    }
}

#if canImport(UIKit)
@MainActor public enum MarkdownEditorClipboard {
    /// Writes Markdown and a plain-text fallback to a UIKit pasteboard.
    public static func write(
        markdown: String,
        plainText: String,
        to pasteboard: UIPasteboard = .general
    ) {
        pasteboard.setItems([[
            UTType.markdown.identifier: markdown,
            UTType.plainText.identifier: plainText
        ]])
    }

    /// Reads Markdown and plain text from a UIKit pasteboard.
    public static func read(from pasteboard: UIPasteboard = .general) -> MarkdownClipboardPayload? {
        let markdown = string(forType: UTType.markdown.identifier, from: pasteboard)
        let plainText = string(forType: UTType.plainText.identifier, from: pasteboard) ?? pasteboard.string
        guard markdown != nil || plainText != nil else {
            return nil
        }
        return MarkdownClipboardPayload(markdown: markdown, plainText: plainText)
    }

    private static func string(forType type: String, from pasteboard: UIPasteboard) -> String? {
        for item in pasteboard.items {
            if let value = item[type] as? String {
                return value
            }
            if let data = item[type] as? Data, let value = String(data: data, encoding: .utf8) {
                return value
            }
        }
        return nil
    }
}
#elseif canImport(AppKit)
@MainActor public enum MarkdownEditorClipboard {
    /// Writes Markdown and a plain-text fallback to an AppKit pasteboard.
    public static func write(
        markdown: String,
        plainText: String,
        to pasteboard: NSPasteboard = .general
    ) {
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: NSPasteboard.PasteboardType(UTType.markdown.identifier))
        pasteboard.setString(plainText, forType: .string)
    }

    /// Reads Markdown and plain text from an AppKit pasteboard.
    public static func read(from pasteboard: NSPasteboard = .general) -> MarkdownClipboardPayload? {
        let markdown = pasteboard.string(forType: NSPasteboard.PasteboardType(UTType.markdown.identifier))
        let plainText = pasteboard.string(forType: .string)
        guard markdown != nil || plainText != nil else {
            return nil
        }
        return MarkdownClipboardPayload(markdown: markdown, plainText: plainText)
    }
}
#endif
