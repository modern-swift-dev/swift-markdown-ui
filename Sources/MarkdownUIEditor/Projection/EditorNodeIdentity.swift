import Foundation

/// A projection-local identifier used to retain native attributes during one build.
struct EditorNodeID: Hashable, Sendable, CustomStringConvertible {
    /// The generated identifier stored in the attributed string.
    fileprivate let rawValue: UUID

    fileprivate init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String {
        rawValue.uuidString
    }
}

/// A stable structural address for a block or inline node in a document.
struct EditorNodePath: Hashable, Sendable, CustomStringConvertible {
    /// One component of a document-relative structural address.
    enum Component: Hashable, Sendable {
        case block(Int)
        case blockquoteBlock(Int)
        case listItem(Int)
        case itemBlock(Int)
        case inline(Int)
        case inlineChild(Int)
        case tableHeader
        case tableRow(Int)
        case tableCell(Int)
    }

    /// Components from the document root to the addressed node.
    var components: [Component]

    init(_ components: [Component] = []) {
        self.components = components
    }

    func appending(_ component: Component) -> Self {
        Self(components + [component])
    }

    var description: String {
        components.map(\.description).joined(separator: "/")
    }
}

private extension EditorNodePath.Component {
    var description: String {
        switch self {
            case let .block(index): "block[\(index)]"
            case let .blockquoteBlock(index): "quote[\(index)]"
            case let .listItem(index): "item[\(index)]"
            case let .itemBlock(index): "itemBlock[\(index)]"
            case let .inline(index): "inline[\(index)]"
            case let .inlineChild(index): "child[\(index)]"
            case .tableHeader: "header"
            case let .tableRow(index): "row[\(index)]"
            case let .tableCell(index): "cell[\(index)]"
        }
    }
}

/// The identity tree stays private because identities only have meaning inside
/// one projection build. Consumers use paths to carry logical state across builds.
final class EditorIdentityTree {
    /// Identifiers allocated for paths during this build.
    private var identities: [EditorNodePath: EditorNodeID] = [:]

    /// Returns the single identifier assigned to `path` for this build.
    func id(for path: EditorNodePath) -> EditorNodeID {
        if let existing = identities[path] {
            return existing
        }
        let id = EditorNodeID()
        identities[path] = id
        return id
    }
}
