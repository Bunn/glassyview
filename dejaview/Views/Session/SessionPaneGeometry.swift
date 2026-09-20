import CoreGraphics

/// Assigns both session panes together so they cannot independently choose the
/// same side of a fold. Coordinates follow SwiftUI's mirrored layout space:
/// minimum x is leading; minimum y is top. Region frames include their margins.
enum SessionPaneGeometry {
    struct Frames: Equatable {
        let content: CGRect
        let controls: CGRect
        let isSeparated: Bool
    }

    static func frames(in bounds: CGRect, divisions: [CGRect], occlusions: [CGRect]) -> Frames {
        // A division that cannot form two usable panes still reserves space.
        // The geometry helper filters invalid and nonintersecting regions.
        let reservedRegions = divisions + occlusions
        let sharedRect = ReservedRegionGeometry.largestClearRect(in: bounds, avoiding: reservedRegions)
        let shared = Frames(content: sharedRect, controls: sharedRect, isSeparated: false)
        guard isUsable(bounds) else { return shared }

        var candidates: [Frames] = []
        for division in divisions where isUsable(division) {
            let band = division.intersection(bounds)
            guard isUsable(band) else { continue }

            let contentBounds: CGRect
            let controlsBounds: CGRect
            if division.width >= division.height {
                // An interior horizontal band must cross this entire local
                // container. An edge-only or partial intersection is not a
                // second usable pane.
                guard division.minX <= bounds.minX, division.maxX >= bounds.maxX,
                      band.minY > bounds.minY, band.maxY < bounds.maxY else { continue }
                contentBounds = CGRect(x: bounds.minX, y: bounds.minY,
                                       width: bounds.width, height: band.minY - bounds.minY)
                controlsBounds = CGRect(x: bounds.minX, y: band.maxY,
                                        width: bounds.width, height: bounds.maxY - band.maxY)
            } else {
                guard division.minY <= bounds.minY, division.maxY >= bounds.maxY,
                      band.minX > bounds.minX, band.maxX < bounds.maxX else { continue }
                contentBounds = CGRect(x: bounds.minX, y: bounds.minY,
                                       width: band.minX - bounds.minX, height: bounds.height)
                controlsBounds = CGRect(x: band.maxX, y: bounds.minY,
                                        width: bounds.maxX - band.maxX, height: bounds.height)
            }

            // Once assigned, a pane may only shrink within its own bounds. All
            // active bands remain reserved, including other reported divisions.
            // Neither pane may move to the other side of the selected division.
            let content = ReservedRegionGeometry.largestClearRect(in: contentBounds, avoiding: reservedRegions)
            let controls = ReservedRegionGeometry.largestClearRect(in: controlsBounds, avoiding: reservedRegions)
            guard isUsable(content), isUsable(controls) else { continue }
            candidates.append(Frames(content: content, controls: controls, isSeparated: true))
        }

        // Prefer the split that gives the smaller pane the most usable area,
        // then the greatest total area. Geometry breaks ties independently of
        // the order in which the system reports regions.
        let normalizeArea = !(bounds.width * bounds.height).isFinite
        func area(_ rect: CGRect) -> CGFloat {
            normalizeArea
                ? (rect.width / bounds.width) * (rect.height / bounds.height)
                : rect.width * rect.height
        }
        return candidates.sorted { left, right in
            let leftAreas = (area(left.content), area(left.controls))
            let rightAreas = (area(right.content), area(right.controls))
            let leftMinimum = min(leftAreas.0, leftAreas.1)
            let rightMinimum = min(rightAreas.0, rightAreas.1)
            if leftMinimum != rightMinimum { return leftMinimum > rightMinimum }
            let leftTotal = leftAreas.0 + leftAreas.1
            let rightTotal = rightAreas.0 + rightAreas.1
            if leftTotal != rightTotal { return leftTotal > rightTotal }
            let leftCoordinates = [left.content.minY, left.content.minX,
                                   left.controls.minY, left.controls.minX,
                                   left.content.height, left.content.width,
                                   left.controls.height, left.controls.width]
            let rightCoordinates = [right.content.minY, right.content.minX,
                                    right.controls.minY, right.controls.minX,
                                    right.content.height, right.content.width,
                                    right.controls.height, right.controls.width]
            return leftCoordinates.lexicographicallyPrecedes(rightCoordinates)
        }.first ?? shared
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width > 0 && rect.size.height > 0
            && rect.maxX.isFinite && rect.maxY.isFinite
    }
}
