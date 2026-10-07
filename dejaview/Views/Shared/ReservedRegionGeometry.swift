import CoreGraphics

/// Places fixed content inside its own bounds, clear of the supplied physical
/// regions. Region frames already include system margins; don't inset them again.
enum ReservedRegionGeometry {
    static func largestClearRect(in bounds: CGRect, avoiding regions: [CGRect]) -> CGRect {
        guard isUsable(bounds) else {
            return CGRect(origin: CGPoint(x: bounds.origin.x.isFinite ? bounds.origin.x : 0,
                                          y: bounds.origin.y.isFinite ? bounds.origin.y : 0),
                          size: .zero)
        }

        let obstacles = regions.compactMap { region -> CGRect? in
            guard isUsable(region) else { return nil }
            let clipped = region.intersection(bounds)
            return isUsable(clipped) ? clipped : nil
        }.sorted {
            $0.minY == $1.minY ? $0.maxY < $1.maxY : $0.minY < $1.minY
        }
        guard !obstacles.isEmpty else { return bounds }

        let xEdges = Set([bounds.minX, bounds.maxX] + obstacles.flatMap { [$0.minX, $0.maxX] })
            .sorted()
        var best = CGRect(origin: bounds.origin, size: .zero)
        var bestArea: CGFloat = 0
        let needsNormalizedArea = !(bounds.width * bounds.height).isFinite

        func consider(left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
            guard right > left, bottom > top else { return }
            let candidate = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            // Ordinary dimensions keep their direct area for predictable ties.
            // Normalize only if finite, extreme bounds could overflow.
            let area = needsNormalizedArea
                ? (candidate.width / bounds.width) * (candidate.height / bounds.height)
                : candidate.width * candidate.height
            if area > bestArea
                || (area == bestArea && (candidate.minY < best.minY
                    || (candidate.minY == best.minY && candidate.minX < best.minX))) {
                best = candidate
                bestArea = area
            }
        }

        // Every maximal rectangle's horizontal edges touch the bounds or an
        // obstacle. For each such span, merge blocked vertical intervals and
        // examine their gaps. This avoids enumerating every x/y edge quartet.
        for leftIndex in 0..<(xEdges.count - 1) {
            let left = xEdges[leftIndex]
            for rightIndex in (leftIndex + 1)..<xEdges.count {
                let right = xEdges[rightIndex]
                var clearTop = bounds.minY
                for obstacle in obstacles where obstacle.minX < right && obstacle.maxX > left {
                    consider(left: left, right: right, top: clearTop, bottom: obstacle.minY)
                    clearTop = max(clearTop, obstacle.maxY)
                    if clearTop >= bounds.maxY { break }
                }
                consider(left: left, right: right, top: clearTop, bottom: bounds.maxY)
            }
        }
        return best
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width > 0 && rect.size.height > 0
            && rect.maxX.isFinite && rect.maxY.isFinite
    }
}
