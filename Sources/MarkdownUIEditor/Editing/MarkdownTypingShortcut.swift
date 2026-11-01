import Foundation

/// A Markdown block marker that, typed at the start of a paragraph, converts it.
enum MarkdownTypingShortcut: Hashable, Sendable {
    /// `#` … `######` then space.
    case heading(MarkdownHeadingLevel)
    /// `-`, `*` or `+` then space.
    case bulletList
    /// A number, then `.` or `)`, then space.
    case orderedList(start: Int)
    /// `[ ]` or `[x]` then space.
    case task(MarkdownTaskState)
    /// `>` then space.
    case blockquote
    /// Three backticks and an optional info string, then Return.
    case codeBlock(info: String?)

    /// Matches the paragraph text before the caret when the user types `typed` there.
    init?(marker: String, typed: String) {
        switch typed {
            case " ":
                guard let shortcut = Self.spaceShortcut(marker) else {
                    return nil
                }
                self = shortcut
            case "\n":
                guard marker.hasPrefix("```") else {
                    return nil
                }
                let info = marker.dropFirst(3).trimmingCharacters(in: .whitespaces)
                guard !info.contains("`") else {
                    return nil
                }
                self = .codeBlock(info: info.isEmpty ? nil : info)
            default:
                return nil
        }
    }

    private static func spaceShortcut(_ marker: String) -> Self? {
        switch marker {
            case "-",
                 "*",
                 "+": return .bulletList
            case ">": return .blockquote
            case "[ ]": return .task(.unchecked)
            case "[x]",
                 "[X]": return .task(.checked)
            default:
                break
        }
        if marker.allSatisfy({ $0 == "#" }), let level = MarkdownHeadingLevel(rawValue: marker.count) {
            return .heading(level)
        }
        // CommonMark allows at most nine digits in an ordered list marker.
        guard let delimiter = marker.last, delimiter == "." || delimiter == ")" else {
            return nil
        }
        let digits = marker.dropLast()
        guard (1 ... 9).contains(digits.count), digits.allSatisfy(\.isASCIIDigit), let start = Int(digits) else {
            return nil
        }
        return .orderedList(start: start)
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
