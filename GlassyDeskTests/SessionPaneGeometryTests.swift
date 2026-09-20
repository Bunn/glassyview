import CoreGraphics
import Testing
@testable import GlassyDesk

struct SessionPaneGeometryTests {
    @Test
    func flatSessionSharesItsWholeContainer() {
        let bounds = CGRect(x: 0, y: 0, width: 466, height: 678)
        let frames = SessionPaneGeometry.frames(in: bounds, divisions: [], occlusions: [])
        #expect(frames == .init(content: bounds, controls: bounds, isSeparated: false))
    }

    @Test
    func horizontalFoldPutsDesktopAboveControllerEvenInAWideContainer() {
        let bounds = CGRect(x: 0, y: 0, width: 950, height: 670)
        let fold = CGRect(x: 0, y: 300, width: 950, height: 30)
        let frames = SessionPaneGeometry.frames(in: bounds, divisions: [fold], occlusions: [])
        #expect(frames.content == CGRect(x: 0, y: 0, width: 950, height: 300))
        #expect(frames.controls == CGRect(x: 0, y: 330, width: 950, height: 340))
        expectSeparated(frames, in: bounds, avoiding: [fold])
    }

    @Test
    func verticalFoldPutsDesktopLeadingAndControllerTrailing() {
        let bounds = CGRect(x: 0, y: 0, width: 670, height: 950)
        let fold = CGRect(x: 320, y: 0, width: 30, height: 950)
        let frames = SessionPaneGeometry.frames(in: bounds, divisions: [fold], occlusions: [])
        #expect(frames.content == CGRect(x: 0, y: 0, width: 320, height: 950))
        #expect(frames.controls == CGRect(x: 350, y: 0, width: 320, height: 950))
        expectSeparated(frames, in: bounds, avoiding: [fold])
    }

    @Test
    func offCenterFoldPreservesBothUnequalPanes() {
        let bounds = CGRect(x: 20, y: 30, width: 900, height: 600)
        let fold = CGRect(x: 220, y: 10, width: 35, height: 650)
        let frames = SessionPaneGeometry.frames(in: bounds, divisions: [fold], occlusions: [])
        #expect(frames.content == CGRect(x: 20, y: 30, width: 200, height: 600))
        #expect(frames.controls == CGRect(x: 255, y: 30, width: 665, height: 600))
        expectSeparated(frames, in: bounds, avoiding: [fold])
    }

    @Test
    func localOriginsAndOversizedHorizontalBandAreClippedCorrectly() {
        let bounds = CGRect(x: 100, y: 200, width: 500, height: 400)
        let fold = CGRect(x: 50, y: 350, width: 700, height: 40)
        let frames = SessionPaneGeometry.frames(in: bounds, divisions: [fold], occlusions: [])
        #expect(frames.content == CGRect(x: 100, y: 200, width: 500, height: 150))
        #expect(frames.controls == CGRect(x: 100, y: 390, width: 500, height: 210))
        expectSeparated(frames, in: bounds, avoiding: [fold])
    }

    @Test
    func partialBandsStillProtectSharedContentWithoutInventingAnExtraPane() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let divisions = [CGRect(x: 50, y: 300, width: 500, height: 30),
                         CGRect(x: 200, y: 50, width: 30, height: 700)]
        let frames = SessionPaneGeometry.frames(in: bounds, divisions: divisions, occlusions: [])
        let expected = CGRect(x: 230, y: 330, width: 370, height: 470)
        #expect(frames == .init(content: expected, controls: expected, isSeparated: false))
        #expect(divisions.allSatisfy { frames.controls.intersection($0).isEmpty })
    }

    @Test
    func edgeOnlyIntersectionsRemainReservedWithoutInventingAnExtraPane() {
        let bounds = CGRect(x: 20, y: 30, width: 600, height: 800)
        let divisions = [CGRect(x: 0, y: 10, width: 650, height: 40),
                         CGRect(x: 0, y: 810, width: 650, height: 40),
                         CGRect(x: 0, y: 0, width: 40, height: 900),
                         CGRect(x: 600, y: 0, width: 40, height: 900)]
        let frames = SessionPaneGeometry.frames(in: bounds, divisions: divisions, occlusions: [])
        let expected = CGRect(x: 40, y: 50, width: 560, height: 760)
        #expect(frames == .init(content: expected, controls: expected, isSeparated: false))
        #expect(divisions.allSatisfy { frames.controls.intersection($0).isEmpty })
    }

    @Test
    func outsideEmptyAndInvalidDivisionsAreIgnored() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let divisions = [CGRect.null, CGRect.infinite, CGRect.zero,
                         CGRect(x: CGFloat.nan, y: 400, width: 600, height: 20),
                         CGRect(x: 300, y: 0, width: -20, height: 800),
                         CGRect(x: 0, y: 900, width: 600, height: 20),
                         CGRect(x: 650, y: 0, width: 20, height: 800)]
        let frames = SessionPaneGeometry.frames(in: bounds, divisions: divisions, occlusions: [])
        #expect(frames == .init(content: bounds, controls: bounds, isSeparated: false))
    }

    @Test
    func cameraWithoutFoldKeepsDesktopAndControlsTogether() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
        let camera = CGRect(x: 170, y: 0, width: 60, height: 60)
        let frames = SessionPaneGeometry.frames(in: bounds, divisions: [], occlusions: [camera])
        let expected = CGRect(x: 0, y: 60, width: 400, height: 540)
        #expect(frames == .init(content: expected, controls: expected, isSeparated: false))
    }

    @Test
    func cameraCanOnlyShrinkItsAssignedPane() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let fold = CGRect(x: 0, y: 280, width: 800, height: 40)
        let camera = CGRect(x: 350, y: 0, width: 100, height: 60)
        let frames = SessionPaneGeometry.frames(in: bounds, divisions: [fold], occlusions: [camera])
        #expect(frames.content == CGRect(x: 0, y: 60, width: 800, height: 220))
        #expect(frames.controls == CGRect(x: 0, y: 320, width: 800, height: 280))
        expectSeparated(frames, in: bounds, avoiding: [fold, camera])
    }

    @Test
    func multipleDivisionsPreferTheMostUsableSmallerPaneRegardlessOfOrder() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let edgeFold = CGRect(x: 0, y: 100, width: 600, height: 20)
        let middleFold = CGRect(x: 0, y: 390, width: 600, height: 20)
        let frames = SessionPaneGeometry.frames(in: bounds, divisions: [edgeFold, middleFold], occlusions: [])
        #expect(frames.content == CGRect(x: 0, y: 120, width: 600, height: 270))
        #expect(frames.controls == CGRect(x: 0, y: 410, width: 600, height: 390))
        #expect(SessionPaneGeometry.frames(in: bounds, divisions: [middleFold, edgeFold], occlusions: []) == frames)
        expectSeparated(frames, in: bounds, avoiding: [edgeFold, middleFold])
    }

    @Test
    func crossingDivisionsKeepBothPanesClearWithDeterministicTieBreaking() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let horizontal = CGRect(x: 0, y: 390, width: 600, height: 20)
        let vertical = CGRect(x: 290, y: 0, width: 20, height: 800)
        let frames = SessionPaneGeometry.frames(in: bounds, divisions: [horizontal, vertical], occlusions: [])
        #expect(frames.content == CGRect(x: 0, y: 0, width: 290, height: 390))
        #expect(frames.controls == CGRect(x: 310, y: 0, width: 290, height: 390))
        #expect(SessionPaneGeometry.frames(in: bounds, divisions: [vertical, horizontal], occlusions: []) == frames)
        expectSeparated(frames, in: bounds, avoiding: [horizontal, vertical])
    }

    @Test
    func selectionAccountsForOccludedAreaInEachCandidate() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let divisions = [CGRect(x: 0, y: 390, width: 600, height: 20),
                         CGRect(x: 0, y: 490, width: 600, height: 20)]
        let camera = CGRect(x: 0, y: 0, width: 600, height: 200)
        let frames = SessionPaneGeometry.frames(in: bounds, divisions: divisions, occlusions: [camera])
        #expect(frames.content == CGRect(x: 0, y: 200, width: 600, height: 190))
        #expect(frames.controls == CGRect(x: 0, y: 510, width: 600, height: 290))
        expectSeparated(frames, in: bounds, avoiding: divisions + [camera])
    }

    @Test
    func fullyOccludedPaneDoesNotAdvertiseAUsableSplit() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let fold = CGRect(x: 0, y: 390, width: 600, height: 20)
        let camera = CGRect(x: 0, y: 0, width: 600, height: 390)
        let frames = SessionPaneGeometry.frames(in: bounds, divisions: [fold], occlusions: [camera])
        #expect(!frames.isSeparated)
        #expect(frames.content == frames.controls)
        #expect(frames.content == CGRect(x: 0, y: 410, width: 600, height: 390))
        #expect(frames.controls.intersection(fold).isEmpty)
        #expect(frames.controls.intersection(camera).isEmpty)
    }

    @Test
    func tinyPositivePanesHaveNoArbitraryMinimumSize() {
        let bounds = CGRect(x: 10, y: 20, width: 1, height: 2)
        let fold = CGRect(x: 10, y: 20.5, width: 1, height: 0.25)
        let frames = SessionPaneGeometry.frames(in: bounds, divisions: [fold], occlusions: [])
        #expect(frames.content == CGRect(x: 10, y: 20, width: 1, height: 0.5))
        #expect(frames.controls == CGRect(x: 10, y: 20.75, width: 1, height: 1.25))
        expectSeparated(frames, in: bounds, avoiding: [fold])
    }

    @Test
    func rtlUsesTheAlreadyMirroredCoordinatesWithoutAnotherFlip() {
        // GeometryProxy's default query mirrors regions and SwiftUI Layout
        // mirrors placement. This helper must not perform a second flip.
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let mirroredFold = CGRect(x: 180, y: 0, width: 20, height: 800)
        let frames = SessionPaneGeometry.frames(in: bounds, divisions: [mirroredFold], occlusions: [])
        #expect(frames.content.minX == 0)
        #expect(frames.content.maxX == 180)
        #expect(frames.controls.minX == 200)
        #expect(frames.controls.maxX == 600)
    }

    @Test
    func invalidBoundsProduceFiniteEmptySharedFrames() {
        let bounds = [CGRect.null, CGRect.infinite,
                      CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
                      CGRect(x: 10, y: 20, width: -10, height: 30),
                      CGRect(x: 10, y: 20, width: 0, height: 30)]
        for rect in bounds {
            let frames = SessionPaneGeometry.frames(in: rect, divisions: [], occlusions: [])
            #expect(!frames.isSeparated)
            #expect(frames.content == frames.controls)
            #expect(frames.content.isEmpty)
            #expect(frames.content.origin.x.isFinite && frames.content.origin.y.isFinite)
        }
    }

    private func expectSeparated(_ frames: SessionPaneGeometry.Frames,
                                 in bounds: CGRect, avoiding regions: [CGRect]) {
        #expect(frames.isSeparated)
        #expect(frames.content.width > 0 && frames.content.height > 0)
        #expect(frames.controls.width > 0 && frames.controls.height > 0)
        #expect(bounds.contains(frames.content) && bounds.contains(frames.controls))
        #expect(frames.content.intersection(frames.controls).isEmpty)
        #expect(regions.allSatisfy { frames.content.intersection($0).isEmpty })
        #expect(regions.allSatisfy { frames.controls.intersection($0).isEmpty })
    }
}
