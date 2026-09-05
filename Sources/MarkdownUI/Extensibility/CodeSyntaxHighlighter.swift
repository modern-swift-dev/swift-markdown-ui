import SwiftUI

/// A type that provides syntax highlighting to code blocks in a Markdown view.
///
/// To configure the current code syntax highlighter for a view hierarchy, use the
/// `markdownCodeSyntaxHighlighter(_:)` modifier.
/// For expensive highlighters with a fixed configuration, retain a wrapper created
/// with ``cached(maximumEntryCount:maximumSourceByteCount:)`` to reuse results
/// across view updates.
public protocol CodeSyntaxHighlighter: Sendable {
    /// Returns a text view configured with the syntax highlighted code.
    /// - Parameters:
    ///   - code: The code block.
    ///   - language: The language of the code block.
    func highlightCode(_ code: String, language: String?) -> Text
}

/// A code syntax highlighter that returns unstyled code blocks.
public struct PlainTextCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    /// Creates a plain text code syntax highlighter.
    public init() {}

    public func highlightCode(_ code: String, language: String?) -> Text {
        Text(code)
    }
}

public extension CodeSyntaxHighlighter where Self == PlainTextCodeSyntaxHighlighter {
    /// A code syntax highlighter that returns unstyled code blocks.
    static var plainText: Self {
        PlainTextCodeSyntaxHighlighter()
    }
}
