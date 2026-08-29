/// Maps native TextKit offsets and selections to Markdown source offsets.
struct ProjectionIndex {
    /// One localized rich projection replacement awaiting materialization.
    private struct ActiveReplacement {
        var unitIndex: Int
        var unit: ProjectionUnit
        var projectionDelta: Int
        var sourceDelta: Int
    }

    /// Leaf units at their last full-build positions.
    private var baseUnits: [ProjectionUnit]
    /// Total UTF-16 length of the native projection.
    private(set) var projectionUTF16Length: Int
    /// Total UTF-16 length of serialized Markdown source.
    private(set) var sourceUTF16Length: Int
    /// Direct lookup for localized unit updates.
    private var unitIndicesByPath: [EditorNodePath: Int]
    /// Length changes applied after one local replacement without shifting later units.
    private var activeReplacement: ActiveReplacement?

    /// Leaf units with the active replacement's deltas applied.
    var units: [ProjectionUnit] {
        guard activeReplacement != nil else {
            return baseUnits
        }
        return baseUnits.indices.map { materializedUnit(at: $0) }
    }

    init(
        units: [ProjectionUnit],
        projectionUTF16Length: Int,
        sourceUTF16Length: Int
    ) {
        self.baseUnits = units.sorted { $0.projectionRange.location < $1.projectionRange.location }
        self.projectionUTF16Length = projectionUTF16Length
        self.sourceUTF16Length = sourceUTF16Length
        self.unitIndicesByPath = Dictionary(
            uniqueKeysWithValues: self.baseUnits.enumerated().map { ($0.element.path, $0.offset) }
        )
        self.activeReplacement = nil
    }

    /// Returns the leaf containing a projected UTF-16 offset.
    func unit(
        atProjectionUTF16Offset offset: Int,
        affinity: SourceAnchor.Affinity = .downstream
    ) -> ProjectionUnit? {
        guard let unitIndex = unitIndex(
            atProjectionUTF16Offset: offset,
            affinity: affinity
        ) else {
            return nil
        }
        return materializedUnit(at: unitIndex)
    }

    /// Returns the leaf at a structural path.
    func unit(at path: EditorNodePath) -> ProjectionUnit? {
        unitIndicesByPath[path].map { materializedUnit(at: $0) }
    }

    func unitIndex(at path: EditorNodePath) -> Int? {
        unitIndicesByPath[path]
    }

    /// Maps a projected boundary into Markdown source.
    func sourceAnchor(
        atProjectionUTF16Offset offset: Int,
        affinity: SourceAnchor.Affinity = .downstream
    ) -> SourceAnchor? {
        guard offset >= 0, offset <= projectionUTF16Length,
              let segment = segment(atProjectionOffset: offset, affinity: affinity) else {
            return nil
        }
        let mapped = Self.map(
            offset,
            fromLocation: segment.projectionRange.location,
            fromLength: segment.projectionRange.length,
            toLocation: segment.sourceRange.location,
            toLength: segment.sourceRange.length,
            affinity: affinity
        )
        return SourceAnchor(utf16Offset: mapped, affinity: affinity)
    }

    /// Maps a Markdown source boundary into the native projection.
    func projectionUTF16Offset(for anchor: SourceAnchor) -> Int? {
        guard anchor.utf16Offset >= 0, anchor.utf16Offset <= sourceUTF16Length,
              let segment = segment(atSourceOffset: anchor.utf16Offset, affinity: anchor.affinity) else {
            return nil
        }
        return Self.map(
            anchor.utf16Offset,
            fromLocation: segment.sourceRange.location,
            fromLength: segment.sourceRange.length,
            toLocation: segment.projectionRange.location,
            toLength: segment.projectionRange.length,
            affinity: anchor.affinity
        )
    }

    func sourceRange(
        forProjectionRange range: ProjectionUTF16Range,
        includingBoundaryMarkup: Bool = false
    ) -> SourceUTF16Range? {
        guard let start = sourceAnchor(
            atProjectionUTF16Offset: range.location,
            affinity: .downstream
        ), let end = sourceAnchor(
            atProjectionUTF16Offset: range.upperBound,
            affinity: .upstream
        ) else {
            return nil
        }

        var lowerBound = min(start.utf16Offset, end.utf16Offset)
        var upperBound = max(start.utf16Offset, end.utf16Offset)
        guard includingBoundaryMarkup else {
            return SourceUTF16Range(location: lowerBound, length: upperBound - lowerBound)
        }

        let leadingSegments = segments(atProjectionBoundary: range.location).filter {
            $0.kind == .hiddenSource &&
                $0.projectionRange.length == 0 &&
                $0.projectionRange.location == range.location
        }
        let trailingSegments = segments(atProjectionBoundary: range.upperBound).filter {
            $0.kind == .hiddenSource &&
                $0.projectionRange.length == 0 &&
                $0.projectionRange.location == range.upperBound
        }

        var expandedLowerBound = lowerBound
        var expandedUpperBound = upperBound
        var foundLeadingMarkup = false
        var foundTrailingMarkup = false
        while let segment = leadingSegments.first(where: { $0.sourceRange.upperBound == expandedLowerBound }) {
            foundLeadingMarkup = true
            expandedLowerBound = segment.sourceRange.location
        }
        while let segment = trailingSegments.first(where: { $0.sourceRange.location == expandedUpperBound }) {
            foundTrailingMarkup = true
            expandedUpperBound = segment.sourceRange.upperBound
        }
        if foundLeadingMarkup, foundTrailingMarkup {
            lowerBound = expandedLowerBound
            upperBound = expandedUpperBound
        }
        return SourceUTF16Range(location: lowerBound, length: upperBound - lowerBound)
    }

    /// Updates every range after an arbitrary projection and source replacement.
    ///
    /// Structural editing uses this general operation. Normal leaf typing uses
    /// ``replaceUnit(at:kind:projectionLength:sourceLength:)`` instead.
    mutating func applyReplacement(
        projectionRange: ProjectionUTF16Range,
        projectionReplacementUTF16Length: Int,
        sourceRange: SourceUTF16Range,
        sourceReplacementUTF16Length: Int
    ) {
        precondition(projectionReplacementUTF16Length >= 0 && sourceReplacementUTF16Length >= 0)
        materializeActiveReplacement()
        let projectionDelta = projectionReplacementUTF16Length - projectionRange.length
        let sourceDelta = sourceReplacementUTF16Length - sourceRange.length

        for index in baseUnits.indices {
            baseUnits[index].projectionRange = Self.adjust(
                baseUnits[index].projectionRange,
                replacing: projectionRange,
                replacementLength: projectionReplacementUTF16Length
            )
            baseUnits[index].sourceRange = Self.adjust(
                baseUnits[index].sourceRange,
                replacing: sourceRange,
                replacementLength: sourceReplacementUTF16Length
            )
            for segmentIndex in baseUnits[index].segments.indices {
                baseUnits[index].segments[segmentIndex].projectionRange = Self.adjust(
                    baseUnits[index].segments[segmentIndex].projectionRange,
                    replacing: projectionRange,
                    replacementLength: projectionReplacementUTF16Length
                )
                baseUnits[index].segments[segmentIndex].sourceRange = Self.adjust(
                    baseUnits[index].segments[segmentIndex].sourceRange,
                    replacing: sourceRange,
                    replacementLength: sourceReplacementUTF16Length
                )
            }
        }
        projectionUTF16Length += projectionDelta
        sourceUTF16Length += sourceDelta
    }

    /// Replaces one rich leaf without rewriting later ranges.
    ///
    /// The replacement has one visible text segment until the next structural
    /// rebuild. Later units keep their full-build positions. Lookups apply the
    /// projection and source deltas when they materialize those units.
    mutating func replaceUnit(
        at path: EditorNodePath,
        kind: ProjectionUnit.Kind? = nil,
        projectionLength: Int,
        sourceLength: Int
    ) -> Bool {
        guard projectionLength >= 0, sourceLength >= 0 else {
            return false
        }
        if let activeReplacement,
           unitIndicesByPath[path] != activeReplacement.unitIndex {
            materializeActiveReplacement()
        }
        guard let unitIndex = unitIndicesByPath[path] else {
            return false
        }

        let baseUnit = baseUnits[unitIndex]
        let previous = activeReplacement?.unit ?? baseUnit
        let replacementProjectionRange = ProjectionUTF16Range(
            location: previous.projectionRange.location,
            length: projectionLength
        )
        let replacementSourceRange = SourceUTF16Range(
            location: previous.sourceRange.location,
            length: sourceLength
        )
        let replacement = ProjectionUnit(
            id: previous.id,
            path: previous.path,
            kind: kind ?? previous.kind,
            projectionRange: replacementProjectionRange,
            sourceRange: replacementSourceRange,
            segments: [
                OffsetMapSegment(
                    projectionRange: replacementProjectionRange,
                    sourceRange: replacementSourceRange,
                    kind: .text
                )
            ]
        )
        activeReplacement = ActiveReplacement(
            unitIndex: unitIndex,
            unit: replacement,
            projectionDelta: projectionLength - baseUnit.projectionRange.length,
            sourceDelta: sourceLength - baseUnit.sourceRange.length
        )
        projectionUTF16Length += projectionLength - previous.projectionRange.length
        sourceUTF16Length += sourceLength - previous.sourceRange.length
        return true
    }

    private func segment(
        atProjectionOffset offset: Int,
        affinity: SourceAnchor.Affinity
    ) -> OffsetMapSegment? {
        guard let unitIndex = unitIndex(
            atProjectionUTF16Offset: offset,
            affinity: affinity
        ) else {
            return nil
        }
        let unit = materializedUnit(at: unitIndex)
        return Self.segment(
            in: unit.segments,
            offset: offset,
            affinity: affinity,
            location: { $0.projectionRange.location },
            length: { $0.projectionRange.length }
        )
    }

    private func segment(
        atSourceOffset offset: Int,
        affinity: SourceAnchor.Affinity
    ) -> OffsetMapSegment? {
        guard let unitIndex = unitIndex(
            atSourceUTF16Offset: offset,
            affinity: affinity
        ) else {
            return nil
        }
        let unit = materializedUnit(at: unitIndex)
        return Self.segment(
            in: unit.segments,
            offset: offset,
            affinity: affinity,
            location: { $0.sourceRange.location },
            length: { $0.sourceRange.length }
        )
    }

    private func unitIndex(
        atProjectionUTF16Offset offset: Int,
        affinity: SourceAnchor.Affinity
    ) -> Int? {
        guard offset >= 0, offset <= projectionUTF16Length, !baseUnits.isEmpty else {
            return nil
        }
        let downstreamIndex: Int
        if let activeReplacement,
           offset >= activeReplacement.unit.projectionRange.location,
           offset < activeReplacement.unit.projectionRange.upperBound ||
           activeReplacement.unitIndex == baseUnits.count - 1 &&
           offset == activeReplacement.unit.projectionRange.upperBound {
            downstreamIndex = activeReplacement.unitIndex
        } else {
            let baseOffset: Int = if let activeReplacement,
                                     offset >= activeReplacement.unit.projectionRange.upperBound {
                offset - activeReplacement.projectionDelta
            } else {
                offset
            }
            guard let index = baseUnitIndex(
                at: baseOffset,
                location: { $0.projectionRange.location },
                upperBound: { $0.projectionRange.upperBound }
            ) else {
                return nil
            }
            downstreamIndex = index
        }
        return upstreamUnitIndex(
            from: downstreamIndex,
            offset: offset,
            affinity: affinity,
            location: { $0.projectionRange.location },
            upperBound: { $0.projectionRange.upperBound }
        )
    }

    private func unitIndex(
        atSourceUTF16Offset offset: Int,
        affinity: SourceAnchor.Affinity
    ) -> Int? {
        guard offset >= 0, offset <= sourceUTF16Length, !baseUnits.isEmpty else {
            return nil
        }
        let downstreamIndex: Int
        if let activeReplacement,
           offset >= activeReplacement.unit.sourceRange.location,
           offset < activeReplacement.unit.sourceRange.upperBound ||
           activeReplacement.unitIndex == baseUnits.count - 1 &&
           offset == activeReplacement.unit.sourceRange.upperBound {
            downstreamIndex = activeReplacement.unitIndex
        } else {
            let baseOffset: Int = if let activeReplacement,
                                     offset >= activeReplacement.unit.sourceRange.upperBound {
                offset - activeReplacement.sourceDelta
            } else {
                offset
            }
            guard let index = baseUnitIndex(
                at: baseOffset,
                location: { $0.sourceRange.location },
                upperBound: { $0.sourceRange.upperBound }
            ) else {
                return nil
            }
            downstreamIndex = index
        }
        return upstreamUnitIndex(
            from: downstreamIndex,
            offset: offset,
            affinity: affinity,
            location: { $0.sourceRange.location },
            upperBound: { $0.sourceRange.upperBound }
        )
    }

    private func baseUnitIndex(
        at offset: Int,
        location: (ProjectionUnit) -> Int,
        upperBound: (ProjectionUnit) -> Int
    ) -> Int? {
        var low = 0
        var high = baseUnits.count
        while low < high {
            let middle = (low + high) / 2
            if location(baseUnits[middle]) <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let index = max(0, low - 1)
        let unit = baseUnits[index]
        guard offset >= location(unit), offset <= upperBound(unit) else {
            return nil
        }
        return index
    }

    private func upstreamUnitIndex(
        from downstreamIndex: Int,
        offset: Int,
        affinity: SourceAnchor.Affinity,
        location: (ProjectionUnit) -> Int,
        upperBound: (ProjectionUnit) -> Int
    ) -> Int {
        guard affinity == .upstream, downstreamIndex > 0 else {
            return downstreamIndex
        }
        let downstream = materializedUnit(at: downstreamIndex)
        let previous = materializedUnit(at: downstreamIndex - 1)
        guard location(downstream) == offset, upperBound(previous) == offset else {
            return downstreamIndex
        }
        return downstreamIndex - 1
    }

    private func materializedUnit(at index: Int) -> ProjectionUnit {
        guard let activeReplacement else {
            return baseUnits[index]
        }
        if index < activeReplacement.unitIndex {
            return baseUnits[index]
        }
        if index == activeReplacement.unitIndex {
            return activeReplacement.unit
        }

        var unit = baseUnits[index]
        unit.projectionRange.location += activeReplacement.projectionDelta
        unit.sourceRange.location += activeReplacement.sourceDelta
        for segmentIndex in unit.segments.indices {
            unit.segments[segmentIndex].projectionRange.location += activeReplacement.projectionDelta
            unit.segments[segmentIndex].sourceRange.location += activeReplacement.sourceDelta
        }
        return unit
    }

    private func segments(atProjectionBoundary offset: Int) -> [OffsetMapSegment] {
        guard let downstreamIndex = unitIndex(
            atProjectionUTF16Offset: offset,
            affinity: .downstream
        ) else {
            return []
        }
        var result = materializedUnit(at: downstreamIndex).segments
        guard downstreamIndex > 0 else {
            return result
        }
        let previous = materializedUnit(at: downstreamIndex - 1)
        if previous.projectionRange.upperBound == offset {
            result.append(contentsOf: previous.segments)
        }
        return result
    }

    private mutating func materializeActiveReplacement() {
        guard activeReplacement != nil else {
            return
        }
        baseUnits = units
        activeReplacement = nil
    }

    private static func segment(
        in segments: [OffsetMapSegment],
        offset: Int,
        affinity: SourceAnchor.Affinity,
        location: (OffsetMapSegment) -> Int,
        length: (OffsetMapSegment) -> Int
    ) -> OffsetMapSegment? {
        guard !segments.isEmpty else {
            return nil
        }
        var low = 0
        var high = segments.count
        while low < high {
            let middle = (low + high) / 2
            if location(segments[middle]) <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }

        var matches: [OffsetMapSegment] = []
        var index = max(0, low - 1)
        while index >= 0 {
            let candidate = segments[index]
            let start = location(candidate)
            let end = start + length(candidate)
            if end < offset {
                break
            }
            if start <= offset, offset <= end {
                matches.append(candidate)
            }
            if index == 0 {
                break
            }
            index -= 1
        }
        index = low
        while index < segments.count && location(segments[index]) <= offset {
            let candidate = segments[index]
            let end = location(candidate) + length(candidate)
            if offset <= end {
                matches.append(candidate)
            }
            index += 1
        }
        guard !matches.isEmpty else {
            return nil
        }

        let nonEmpty = matches.filter { length($0) > 0 }
        let candidates = nonEmpty.isEmpty ? matches : nonEmpty
        switch affinity {
            case .upstream:
                let endingAtOffset = candidates.filter { location($0) + length($0) == offset }
                return (endingAtOffset.isEmpty ? candidates : endingAtOffset).max {
                    location($0) < location($1)
                }
            case .downstream:
                let startingAtOffset = candidates.filter { location($0) == offset }
                return (startingAtOffset.isEmpty ? candidates : startingAtOffset).min {
                    let lhsEnd = location($0) + length($0)
                    let rhsEnd = location($1) + length($1)
                    return lhsEnd < rhsEnd
                }
        }
    }

    private static func map(
        _ offset: Int,
        fromLocation: Int,
        fromLength: Int,
        toLocation: Int,
        toLength: Int,
        affinity: SourceAnchor.Affinity
    ) -> Int {
        if fromLength == toLength {
            return toLocation + min(max(offset - fromLocation, 0), toLength)
        }
        if fromLength == 0 {
            return affinity == .upstream ? toLocation : toLocation + toLength
        }
        if toLength == 0 {
            return toLocation
        }
        let relativeOffset = min(max(offset - fromLocation, 0), fromLength)
        if relativeOffset == 0 {
            return toLocation
        }
        if relativeOffset == fromLength {
            return toLocation + toLength
        }
        return affinity == .upstream ? toLocation : toLocation + toLength
    }

    private static func adjust(
        _ range: ProjectionUTF16Range,
        replacing replaced: ProjectionUTF16Range,
        replacementLength: Int
    ) -> ProjectionUTF16Range {
        let delta = replacementLength - replaced.length
        if replaced.length == 0 {
            if range.location >= replaced.location {
                return ProjectionUTF16Range(location: range.location + delta, length: range.length)
            }
            if range.upperBound > replaced.location {
                return ProjectionUTF16Range(location: range.location, length: range.length + delta)
            }
            return range
        }
        if range.upperBound <= replaced.location {
            return range
        }
        if range.location >= replaced.upperBound {
            return ProjectionUTF16Range(location: range.location + delta, length: range.length)
        }
        let newEnd = max(replaced.location + replacementLength, range.upperBound + delta)
        let newStart = min(range.location, replaced.location)
        return ProjectionUTF16Range(location: newStart, length: max(0, newEnd - newStart))
    }

    private static func adjust(
        _ range: SourceUTF16Range,
        replacing replaced: SourceUTF16Range,
        replacementLength: Int
    ) -> SourceUTF16Range {
        let delta = replacementLength - replaced.length
        if replaced.length == 0 {
            if range.location >= replaced.location {
                return SourceUTF16Range(location: range.location + delta, length: range.length)
            }
            if range.upperBound > replaced.location {
                return SourceUTF16Range(location: range.location, length: range.length + delta)
            }
            return range
        }
        if range.upperBound <= replaced.location {
            return range
        }
        if range.location >= replaced.upperBound {
            return SourceUTF16Range(location: range.location + delta, length: range.length)
        }
        let newEnd = max(replaced.location + replacementLength, range.upperBound + delta)
        let newStart = min(range.location, replaced.location)
        return SourceUTF16Range(location: newStart, length: max(0, newEnd - newStart))
    }
}
