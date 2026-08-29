import CoreGraphics

/// Owns the absolute remote cursor target for one relative touch gesture.
///
/// Keeping this target separate from the session's reported cursor position is
/// important for transports that also receive delayed host cursor telemetry.
/// Each finger sample advances from the last locally applied target, so an old
/// server sample can never rebase an in-progress gesture.
struct RelativePointerAccumulator {
    private(set) var target: CGPoint?
    private var touchOrigin: CGPoint?
    private var lastTouchLocation: CGPoint?
    private var currentTouchLocation: CGPoint?

    mutating func begin(touchLocation: CGPoint, cursorLocation: CGPoint) {
        guard Self.isFinite(touchLocation), Self.isFinite(cursorLocation) else {
            reset()
            return
        }

        target = cursorLocation
        touchOrigin = touchLocation
        lastTouchLocation = touchLocation
        currentTouchLocation = touchLocation
    }

    /// Advances the remote target by one incremental UIKit touch sample.
    /// Returns nil when the gesture has not begun or the sample is invalid.
    mutating func advance(
        to touchLocation: CGPoint,
        framebufferScale: CGFloat
    ) -> CGPoint? {
        guard let lastTouchLocation,
              let target,
              Self.isFinite(touchLocation),
              framebufferScale.isFinite,
              framebufferScale > 0 else { return nil }

        self.lastTouchLocation = touchLocation
        currentTouchLocation = touchLocation

        let delta = CGPoint(
            x: (touchLocation.x - lastTouchLocation.x) / framebufferScale,
            y: (touchLocation.y - lastTouchLocation.y) / framebufferScale
        )
        guard delta != .zero else { return nil }

        let advancedTarget = CGPoint(
            x: target.x + delta.x,
            y: target.y + delta.y
        )
        guard Self.isFinite(advancedTarget) else { return nil }

        self.target = advancedTarget
        return advancedTarget
    }

    /// Replaces the requested target with the transport's synchronously
    /// applied value. This captures framebuffer-edge clamping and prevents a
    /// hidden overshoot that would otherwise delay movement after reversing.
    mutating func synchronizeTarget(to appliedTarget: CGPoint) {
        guard target != nil, Self.isFinite(appliedTarget) else { return }
        target = appliedTarget
    }

    func hasMoved(beyond threshold: CGFloat) -> Bool {
        guard threshold.isFinite,
              threshold >= 0,
              let touchOrigin,
              let currentTouchLocation else { return false }

        return abs(currentTouchLocation.x - touchOrigin.x)
            + abs(currentTouchLocation.y - touchOrigin.y) > threshold
    }

    mutating func reset() {
        target = nil
        touchOrigin = nil
        lastTouchLocation = nil
        currentTouchLocation = nil
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }
}
