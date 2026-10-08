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

    /// The same address after top-level blocks are inserted or removed before it.
    func shiftingRootBlock(by delta: Int) -> Self {
        guard delta != 0, case let .block(index)? = components.first else {
            return self
        }
        var copy = self
        copy.components[0] = .block(index + delta)
        return copy
    }

    /// The top-level block containing the addressed node.
    var rootBlockIndex: Int? {
        guard case let .block(index)? = components.first else {
            return nil
        }
        return index
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

/// A path captured by attachment callbacks that stays current when earlier blocks change.
@MainActor final class EditorPathReference {
    var path: EditorNodePath

    init(_ path: EditorNodePath) {
        self.path = path
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
