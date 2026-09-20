import CoreGraphics
import Testing
@testable import GlassyDesk

struct ReservedRegionGeometryTests {
    @Test
    func unreservedBoundsAreUnchanged() {
        let bounds = CGRect(x: 23, y: 41, width: 320, height: 260)
        #expect(ReservedRegionGeometry.largestClearRect(in: bounds, avoiding: []) == bounds)
    }

    @Test
    func verticalFoldChoosesTheLargerPaneWithoutAddingMargins() {
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        let fold = CGRect(x: 440, y: 0, width: 40, height: 700)
        let result = ReservedRegionGeometry.largestClearRect(in: bounds, avoiding: [fold])
        #expect(result == CGRect(x: 480, y: 0, width: 520, height: 700))
        expectUsable(result, in: bounds, avoiding: [fold])
    }

    @Test
    func horizontalFoldTiePrefersTheUpperPane() {
        let bounds = CGRect(x: 0, y: 0, width: 700, height: 1_000)
        let fold = CGRect(x: 0, y: 480, width: 700, height: 40)
        let result = ReservedRegionGeometry.largestClearRect(in: bounds, avoiding: [fold])
        #expect(result == CGRect(x: 0, y: 0, width: 700, height: 480))
        expectUsable(result, in: bounds, avoiding: [fold])
    }

    @Test
    func equalPhysicalPanesChooseMinXIndependentOfSemanticDirection() {
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        let fold = CGRect(x: 480, y: 0, width: 40, height: 700)
        // Callers supply physical, unmirrored frames, including in RTL.
        #expect(ReservedRegionGeometry.largestClearRect(in: bounds, avoiding: [fold])
                == CGRect(x: 0, y: 0, width: 480, height: 700))
    }

    @Test
    func edgeCameraLeavesTheRestOfTheWidthUsable() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
        let camera = CGRect(x: 330, y: -20, width: 90, height: 100)
        let result = ReservedRegionGeometry.largestClearRect(in: bounds, avoiding: [camera])
        #expect(result == CGRect(x: 0, y: 80, width: 400, height: 520))
        expectUsable(result, in: bounds, avoiding: [camera])
    }

    @Test
    func foldAndCameraAreAvoidedTogether() {
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        let regions = [CGRect(x: 480, y: 0, width: 40, height: 700),
                       CGRect(x: 200, y: 0, width: 80, height: 80)]
        let result = ReservedRegionGeometry.largestClearRect(in: bounds, avoiding: regions)
        #expect(result == CGRect(x: 520, y: 0, width: 480, height: 700))
        expectUsable(result, in: bounds, avoiding: regions)
    }

    @Test
    func overlappingRegionsAreMergedAndInputOrderDoesNotMatter() {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 500)
        let regions = [CGRect(x: 0, y: 120, width: 500, height: 100),
                       CGRect(x: 0, y: 180, width: 500, height: 100),
                       CGRect(x: 0, y: 190, width: 500, height: 20)]
        let result = ReservedRegionGeometry.largestClearRect(in: bounds, avoiding: regions)
        #expect(result == CGRect(x: 0, y: 280, width: 500, height: 220))
        #expect(ReservedRegionGeometry.largestClearRect(in: bounds, avoiding: regions.reversed()) == result)
        expectUsable(result, in: bounds, avoiding: regions)
    }

    @Test
    func localOriginsAndPartiallyIntersectingRegionsAreRespected() {
        let bounds = CGRect(x: 100, y: 200, width: 400, height: 300)
        let regions = [CGRect(x: 50, y: 150, width: 90, height: 500),
                       CGRect(x: 120, y: 450, width: 600, height: 90)]
        let result = ReservedRegionGeometry.largestClearRect(in: bounds, avoiding: regions)
        #expect(result == CGRect(x: 140, y: 200, width: 360, height: 250))
        expectUsable(result, in: bounds, avoiding: regions)
    }

    @Test
    func emptyInvalidAndOutsideRegionsDoNotShrinkContent() {
        let bounds = CGRect(x: 20, y: 30, width: 300, height: 200)
        let regions = [CGRect.zero, CGRect.null, CGRect.infinite,
                       CGRect(x: CGFloat.nan, y: 30, width: 10, height: 10),
                       CGRect(x: 40, y: 50, width: -20, height: 20),
                       CGRect(x: 320, y: 30, width: 20, height: 20),
                       CGRect(x: -100, y: -100, width: 10, height: 10)]
        #expect(ReservedRegionGeometry.largestClearRect(in: bounds, avoiding: regions) == bounds)
    }

    @Test
    func tinyRemainingAreaIsRetainedWithoutAnArtificialMinimum() {
        let bounds = CGRect(x: 10, y: 20, width: 1, height: 1)
        let regions = [CGRect(x: 10, y: 20, width: 0.75, height: 1),
                       CGRect(x: 10, y: 20, width: 1, height: 0.5)]
        let result = ReservedRegionGeometry.largestClearRect(in: bounds, avoiding: regions)
        #expect(result == CGRect(x: 10.75, y: 20.5, width: 0.25, height: 0.5))
        expectUsable(result, in: bounds, avoiding: regions)
    }

    @Test
    func fullyBlockedBoundsReturnAnEmptyRectAtTheirOwnOrigin() {
        let bounds = CGRect(x: 70, y: 90, width: 300, height: 200)
        let regions = [CGRect(x: 60, y: 80, width: 160, height: 220),
                       CGRect(x: 210, y: 80, width: 200, height: 220)]
        #expect(ReservedRegionGeometry.largestClearRect(in: bounds, avoiding: regions)
                == CGRect(origin: bounds.origin, size: .zero))
    }

    @Test
    func emptyOrInvalidBoundsDoNotProduceInvalidOutput() {
        #expect(ReservedRegionGeometry.largestClearRect(in: CGRect(x: 40, y: 50, width: 0, height: 20),
                                                       avoiding: [])
                == CGRect(x: 40, y: 50, width: 0, height: 0))
        let result = ReservedRegionGeometry.largestClearRect(in: .null, avoiding: [])
        #expect(result == .zero)
    }

    @Test
    func clearAreaMatchesAnExhaustiveIndependentOracle() {
        let bounds = CGRect(x: 0, y: 0, width: 8, height: 7)
        let arrangements: [[CGRect]] = [
            [CGRect(x: 2, y: 1, width: 2, height: 2), CGRect(x: 5, y: 4, width: 2, height: 2)],
            [CGRect(x: 1, y: 0, width: 2, height: 5), CGRect(x: 5, y: 2, width: 3, height: 2)],
            [CGRect(x: 0, y: 2, width: 8, height: 1), CGRect(x: 3, y: 0, width: 1, height: 7)],
            [CGRect(x: 1, y: 1, width: 6, height: 5)],
        ]
        for regions in arrangements {
            let result = ReservedRegionGeometry.largestClearRect(in: bounds, avoiding: regions)
            var largestArea: CGFloat = 0
            var preferredOrigin = bounds.origin
            for x in 0..<8 {
                for y in 0..<7 {
                    for width in 1...(8 - x) {
                        for height in 1...(7 - y) {
                            let candidate = CGRect(x: x, y: y, width: width, height: height)
                            if regions.allSatisfy({ candidate.intersection($0).isEmpty }) {
                                let area = candidate.width * candidate.height
                                if area > largestArea
                                    || (area == largestArea && (candidate.minY < preferredOrigin.y
                                        || (candidate.minY == preferredOrigin.y && candidate.minX < preferredOrigin.x))) {
                                    largestArea = area
                                    preferredOrigin = candidate.origin
                                }
                            }
                        }
                    }
                }
            }
            #expect(result.width * result.height == largestArea)
            #expect(result.origin == preferredOrigin)
            expectUsable(result, in: bounds, avoiding: regions)
        }
    }

    private func expectUsable(_ result: CGRect, in bounds: CGRect, avoiding regions: [CGRect]) {
        #expect(result.width > 0 && result.height > 0)
        #expect(bounds.contains(result))
        #expect(regions.allSatisfy { result.intersection($0).isEmpty })
    }
}
