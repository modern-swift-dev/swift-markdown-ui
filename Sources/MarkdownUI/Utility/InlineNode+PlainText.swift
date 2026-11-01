import Foundation

extension Sequence<InlineNode> {
    func renderPlainText() -> String {
        var text = ""
        self.appendPlainText(to: &text)
        return text
    }

    private func appendPlainText(to text: inout String) {
        for inline in self {
            switch inline {
                case let .text(content),
                     let .code(content),
                     let .html(content):
                    text.append(contentsOf: content)
                case .softBreak:
                    text.append(" ")
                case .lineBreak:
                    text.append("\n")
                default:
                    inline.children.appendPlainText(to: &text)
            }
        }
    }
}

extension Sequence<InlineNode> {
    /// The heading's rendered text, which its identifier is generated from.
    ///
    /// Unlike ``renderPlainText()``, raw HTML and images add nothing, as on GitHub.
    func renderHeadingText() -> String {
        var text = ""
        self.appendHeadingText(to: &text)
        return text
    }

    private func appendHeadingText(to text: inout String) {
        for inline in self {
            switch inline {
                case let .text(content),
                     let .code(content):
                    text.append(contentsOf: content)
                case .softBreak:
                    text.append(" ")
                case .lineBreak:
                    text.append("\n")
                case .html,
                     .image:
                    break
                default:
                    inline.children.appendHeadingText(to: &text)
            }
        }
    }
}
