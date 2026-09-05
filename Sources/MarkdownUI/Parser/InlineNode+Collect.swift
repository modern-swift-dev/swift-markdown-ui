import Foundation

extension Sequence<InlineNode> {
    func collect<Result>(_ c: (InlineNode) throws -> [Result]) rethrows -> [Result] {
        var result: [Result] = []
        try self.collect(c, into: &result)
        return result
    }

    fileprivate func collect<Result>(
        _ c: (InlineNode) throws -> [Result], into result: inout [Result]
    ) rethrows {
        for inline in self {
            try inline.children.collect(c, into: &result)
            result.append(contentsOf: try c(inline))
        }
    }
}

extension InlineNode {
    func collect<Result>(_ c: (InlineNode) throws -> [Result]) rethrows -> [Result] {
        var result: [Result] = []
        try self.children.collect(c, into: &result)
        result.append(contentsOf: try c(self))
        return result
    }
}
