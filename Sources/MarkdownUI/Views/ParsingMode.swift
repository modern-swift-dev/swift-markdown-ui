/// Controls when a Markdown view parses its Markdown-formatted string.
public enum ParsingMode: Sendable {
    /// Parses the string on the main actor while the view computes its body.
    ///
    /// The view shows the content of a new string as soon as it updates. This is the behavior of
    /// ``MarkdownView/init(_:baseURL:imageBaseURL:)-(String,_,_)``.
    case synchronous
    /// Parses the string in a background task.
    ///
    /// The view keeps showing the previous content, or nothing before the first parse finishes,
    /// until the new string is parsed. A new string cancels a parse that is out of date, so the
    /// view only shows the content of the latest string. Use this mode for large documents,
    /// whose parsing would otherwise block the user interface.
    case background
}
