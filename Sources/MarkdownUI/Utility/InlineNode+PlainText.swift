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
