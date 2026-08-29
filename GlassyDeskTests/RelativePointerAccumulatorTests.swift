import CoreGraphics
import Testing
@testable import GlassyDesk

struct RelativePointerAccumulatorTests {
    @Test
    func localTargetDoesNotRebaseBetweenSamples() {
        var accumulator = RelativePointerAccumulator()
        accumulator.begin(
            touchLocation: CGPoint(x: 10, y: 10),
            cursorLocation: CGPoint(x: 100, y: 100)
        )

        let firstTarget = accumulator.advance(
            to: CGPoint(x: 20, y: 10),
            framebufferScale: 1
        )
        #expect(firstTarget == CGPoint(x: 110, y: 100))
        accumulator.synchronizeTarget(to: CGPoint(x: 110, y: 100))

        // A delayed transport cursor report is deliberately not an input to
        // this accumulator. The next sample continues from the local target.
        let secondTarget = accumulator.advance(
            to: CGPoint(x: 30, y: 10),
            framebufferScale: 1
        )
        #expect(secondTarget == CGPoint(x: 120, y: 100))
    }

    @Test
    func movementStartsBeforeTapThresholdAndStillClassifiesTapTravel() {
        var accumulator = RelativePointerAccumulator()
        accumulator.begin(
            touchLocation: .zero,
            cursorLocation: CGPoint(x: 50, y: 50)
        )

        let firstTarget = accumulator.advance(
            to: CGPoint(x: 2, y: 1),
            framebufferScale: 1
        )
        #expect(firstTarget == CGPoint(x: 52, y: 51))
        #expect(!accumulator.hasMoved(beyond: 8))

        let secondTarget = accumulator.advance(
            to: CGPoint(x: 8, y: 2),
            framebufferScale: 1
        )
        #expect(secondTarget == CGPoint(x: 58, y: 52))
        #expect(accumulator.hasMoved(beyond: 8))
    }

    @Test
    func scaleConversionAndClampedEdgeReversal() {
        var accumulator = RelativePointerAccumulator()
        accumulator.begin(
            touchLocation: .zero,
            cursorLocation: CGPoint(x: 99, y: 40)
        )

        let overshootingTarget = accumulator.advance(
            to: CGPoint(x: 20, y: 10),
            framebufferScale: 2
        )
        #expect(overshootingTarget == CGPoint(x: 109, y: 45))

        // Simulate the session clamping the horizontal target to its edge.
        accumulator.synchronizeTarget(to: CGPoint(x: 100, y: 45))
        let reversedTarget = accumulator.advance(
            to: CGPoint(x: 18, y: 10),
            framebufferScale: 2
        )
        #expect(reversedTarget == CGPoint(x: 99, y: 45))
    }

    @Test
    func invalidSamplesCannotPoisonTarget() {
        var accumulator = RelativePointerAccumulator()
        accumulator.begin(
            touchLocation: .zero,
            cursorLocation: CGPoint(x: 20, y: 30)
        )

        let invalidTarget = accumulator.advance(
            to: CGPoint(x: CGFloat.infinity, y: 0),
            framebufferScale: 1
        )
        #expect(invalidTarget == nil)
        #expect(accumulator.target == CGPoint(x: 20, y: 30))

        accumulator.reset()
        #expect(accumulator.target == nil)
    }
}
