import Foundation

/// A document's blocks with each heading carrying its unique GitHub-compatible identifier.
struct HeadingIdentifiers {
    let blocks: [BlockNode]
    /// The heading identifiers in document order.
    let identifiers: [String]

    init(_ blocks: [BlockNode]) {
        var slugger = HeadingSlugger()
        var identifiers: [String] = []
        self.blocks = blocks.rewrite { (block: BlockNode) -> [BlockNode] in
            guard case let .heading(level, content, _) = block else {
                return [block]
            }
            let identifier = slugger.identifier(for: content.renderPlainText())
            identifiers.append(identifier)
            return [.heading(level: level, content: content, identifier: identifier)]
        }
        self.identifiers = identifiers
    }
}

/// Retains the identified blocks for one mounted Markdown view while its blocks are unchanged.
@MainActor final class HeadingIdentifierCache {
    private var last: (blocks: [BlockNode], headings: HeadingIdentifiers)?

    func headings(in blocks: [BlockNode]) -> HeadingIdentifiers {
        if let last = self.last, last.blocks == blocks {
            return last.headings
        }
        let headings = HeadingIdentifiers(blocks)
        self.last = (blocks, headings)
        return headings
    }
}
