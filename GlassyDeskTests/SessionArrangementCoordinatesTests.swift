import CoreGraphics
import SwiftUI
import Testing
@testable import GlassyDesk

struct SessionArrangementCoordinatesTests {
    @Test
    func asymmetricVisibleBoundsUseTheUnobscuredLocalOrigin() {
        let unobscured = CGRect(x: 70, y: 90, width: 600, height: 800)
        let visible = CGRect(x: 100, y: 125, width: 550, height: 400)
        #expect(SessionPaneCoordinates.visibleBounds(visibleGlobalFrame: visible,
                                                     unobscuredGlobalFrame: unobscured,
                                                     layoutDirection: .leftToRight)
                == CGRect(x: 30, y: 35, width: 550, height: 400))
        #expect(SessionPaneCoordinates.visibleBounds(visibleGlobalFrame: visible,
                                                     unobscuredGlobalFrame: unobscured,
                                                     layoutDirection: .rightToLeft)
                == CGRect(x: 20, y: 35, width: 550, height: 400))
    }

    @Test
    func movingTheWholeContainerDoesNotChangeItsLocalViewport() {
        let unobscured = CGRect(x: 70, y: 90, width: 600, height: 800)
        let visible = CGRect(x: 100, y: 125, width: 550, height: 400)
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let original = SessionPaneCoordinates.visibleBounds(visibleGlobalFrame: visible,
                                                                unobscuredGlobalFrame: unobscured,
                                                                layoutDirection: direction)
            let translated = SessionPaneCoordinates.visibleBounds(
                visibleGlobalFrame: visible.offsetBy(dx: -45, dy: 33),
                unobscuredGlobalFrame: unobscured.offsetBy(dx: -45, dy: 33),
                layoutDirection: direction
            )
            #expect(translated == original)
        }
    }

    @Test
    func landscapeBoundsUseCurrentWidthForSemanticLeading() {
        let unobscured = CGRect(x: 50, y: 80, width: 800, height: 600)
        let visible = CGRect(x: 63, y: 97, width: 752, height: 311)
        #expect(SessionPaneCoordinates.visibleBounds(visibleGlobalFrame: visible,
                                                     unobscuredGlobalFrame: unobscured,
                                                     layoutDirection: .leftToRight)
                == CGRect(x: 13, y: 17, width: 752, height: 311))
        #expect(SessionPaneCoordinates.visibleBounds(visibleGlobalFrame: visible,
                                                     unobscuredGlobalFrame: unobscured,
                                                     layoutDirection: .rightToLeft)
                == CGRect(x: 35, y: 17, width: 752, height: 311))
    }
}
