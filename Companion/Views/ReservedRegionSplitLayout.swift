import CoreGraphics

/// Calculates contiguous pane frames around a fold or another division reserved by the system.
/// The view layer supplies only active regions, so ordinary iPhones and a flat iPhone Duo keep
/// the Mac's saved split proportions exactly.
enum ReservedRegionSplitLayout {
    static func frames(
        in size: CGSize,
        horizontal: Bool,
        itemCount: Int,
        weights: [Double],
        reservedRegions: [CGRect],
        spacing: CGFloat = 1,
        rightToLeft: Bool = false
    ) -> [CGRect] {
        guard itemCount > 0 else { return [] }
        guard size.width > 0, size.height > 0 else {
            return Array(repeating: .zero, count: itemCount)
        }
        let normalized = normalizedWeights(weights, count: itemCount)
        let layoutWeights = horizontal && rightToLeft ? Array(normalized.reversed()) : normalized
        let primaryLength = horizontal ? size.width : size.height
        let secondaryLength = horizontal ? size.height : size.width

        guard let division = divisionInterval(
            primaryLength: primaryLength,
            secondaryLength: secondaryLength,
            horizontal: horizontal,
            reservedRegions: reservedRegions
        ), layoutWeights.count > 1 else {
            return viewOrderAdjusted(frames(
                for: layoutWeights.indices,
                origin: 0,
                length: primaryLength,
                secondaryLength: secondaryLength,
                horizontal: horizontal,
                weights: layoutWeights,
                spacing: spacing
            ), horizontal: horizontal, rightToLeft: rightToLeft)
        }

        let availableBefore = division.lowerBound
        let availableAfter = primaryLength - division.upperBound
        let availableLength = availableBefore + availableAfter
        guard availableBefore > 0, availableAfter > 0, availableLength > 0 else {
            return viewOrderAdjusted(frames(
                for: layoutWeights.indices,
                origin: 0,
                length: primaryLength,
                secondaryLength: secondaryLength,
                horizontal: horizontal,
                weights: layoutWeights,
                spacing: spacing
            ), horizontal: horizontal, rightToLeft: rightToLeft)
        }

        let targetFraction = availableBefore / availableLength
        let boundary = nearestBoundary(to: targetFraction, weights: layoutWeights)
        let leading = frames(
            for: 0..<boundary,
            origin: 0,
            length: availableBefore,
            secondaryLength: secondaryLength,
            horizontal: horizontal,
            weights: layoutWeights,
            spacing: spacing
        )
        let trailing = frames(
            for: boundary..<layoutWeights.count,
            origin: division.upperBound,
            length: availableAfter,
            secondaryLength: secondaryLength,
            horizontal: horizontal,
            weights: layoutWeights,
            spacing: spacing
        )
        return viewOrderAdjusted(leading + trailing,
                                 horizontal: horizontal, rightToLeft: rightToLeft)
    }

    private static func normalizedWeights(_ weights: [Double], count: Int) -> [CGFloat] {
        guard weights.count == count, weights.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return Array(repeating: 1 / CGFloat(count), count: count)
        }
        let total = weights.reduce(0, +)
        guard total.isFinite, total > 0 else {
            return Array(repeating: 1 / CGFloat(count), count: count)
        }
        return weights.map { CGFloat($0 / total) }
    }

    private static func divisionInterval(
        primaryLength: CGFloat,
        secondaryLength: CGFloat,
        horizontal: Bool,
        reservedRegions: [CGRect]
    ) -> ClosedRange<CGFloat>? {
        let candidates = reservedRegions.compactMap { region -> ClosedRange<CGFloat>? in
            let primaryStart = horizontal ? region.minX : region.minY
            let primaryEnd = horizontal ? region.maxX : region.maxY
            let crossStart = horizontal ? region.minY : region.minX
            let crossEnd = horizontal ? region.maxY : region.maxX
            let clippedStart = max(0, primaryStart)
            let clippedEnd = min(primaryLength, primaryEnd)
            let clippedCross = max(0, min(secondaryLength, crossEnd) - max(0, crossStart))
            guard clippedEnd > clippedStart, clippedCross >= secondaryLength * 0.5 else { return nil }
            return clippedStart...clippedEnd
        }
        return candidates.max { lhs, rhs in
            (lhs.upperBound - lhs.lowerBound) < (rhs.upperBound - rhs.lowerBound)
        }
    }

    private static func nearestBoundary(to target: CGFloat, weights: [CGFloat]) -> Int {
        var cumulative: CGFloat = 0
        var bestIndex = 1
        var bestDistance = CGFloat.infinity
        for index in 1..<weights.count {
            cumulative += weights[index - 1]
            let distance = abs(cumulative - target)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    private static func viewOrderAdjusted(
        _ frames: [CGRect],
        horizontal: Bool,
        rightToLeft: Bool
    ) -> [CGRect] {
        guard horizontal, rightToLeft else { return frames }
        return Array(frames.reversed())
    }

    private static func frames(
        for indices: Range<Int>,
        origin: CGFloat,
        length: CGFloat,
        secondaryLength: CGFloat,
        horizontal: Bool,
        weights: [CGFloat],
        spacing: CGFloat
    ) -> [CGRect] {
        guard !indices.isEmpty else { return [] }
        let gaps = spacing * CGFloat(max(0, indices.count - 1))
        let contentLength = max(0, length - gaps)
        let weightTotal = indices.reduce(CGFloat.zero) { $0 + weights[$1] }
        var cursor = origin
        return indices.map { index in
            let itemLength = weightTotal > 0 ? contentLength * weights[index] / weightTotal : 0
            defer { cursor += itemLength + spacing }
            if horizontal {
                return CGRect(x: cursor, y: 0, width: itemLength, height: secondaryLength)
            }
            return CGRect(x: 0, y: cursor, width: secondaryLength, height: itemLength)
        }
    }
}
