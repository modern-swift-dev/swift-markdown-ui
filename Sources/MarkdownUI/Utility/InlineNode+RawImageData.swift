import Foundation

struct RawImageData: Hashable {
    var source: String
    var alt: String
    var destination: String?
}

extension InlineNode {
    var imageData: RawImageData? {
        switch self {
            case let .image(source, children):
                return .init(source: source, alt: children.renderPlainText())
            case let .link(destination, children) where children.count == 1:
                guard var imageData = children.first?.imageData else {
                    return nil
                }
                imageData.destination = destination
                return imageData
            default:
                return nil
        }
    }
}

extension Sequence<InlineNode> {
    func inlineImageData() -> [RawImageData] {
        self.flatMap { inline -> [RawImageData] in
            switch inline {
                case let .image(source, children):
                    return [.init(source: source, alt: children.renderPlainText())]
                default:
                    return inline.children.inlineImageData()
            }
        }
    }
}
