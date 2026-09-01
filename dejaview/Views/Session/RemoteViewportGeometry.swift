import CoreGraphics

/// Pure viewport interaction math shared by VNC and Glassy Stream.
///
/// Keeping this separate from UIKit makes the two important policies explicit:
/// dragging moves the canvas with the fingers, and cursor following reveals an
/// edge when the cursor enters a small activation band instead of continuously
/// re-centering.
enum RemoteViewportGeometry {
    struct PannableAxes: OptionSet {
        let rawValue: UInt8

        static let horizontal = PannableAxes(rawValue: 1 << 0)
        static let vertical = PannableAxes(rawValue: 1 << 1)
    }

    enum GestureIntent: Equatable {
        case undecided
        case viewportPan
        case remoteScroll
    }

    static func pannableAxes(contentSize: CGSize,
                             viewportSize: CGSize,
                             effectiveScale: CGFloat) -> PannableAxes {
        guard contentSize.isUsable,
              viewportSize.isUsable,
              effectiveScale.isFinite,
              effectiveScale > 0 else {
            return []
        }

        var axes: PannableAxes = []
        let tolerance: CGFloat = 0.5

        if contentSize.width * effectiveScale > viewportSize.width + tolerance {
            axes.insert(.horizontal)
        }
        if contentSize.height * effectiveScale > viewportSize.height + tolerance {
            axes.insert(.vertical)
        }

        return axes
    }

    static func gestureIntent(pannableAxes: PannableAxes,
                              pansViewportWithTwoFingers: Bool,
                              forcesViewportPan: Bool = false) -> GestureIntent {
        (pansViewportWithTwoFingers || forcesViewportPan) && !pannableAxes.isEmpty
            ? .viewportPan
            : .remoteScroll
    }

    static func shouldCommitRemoteScroll(translation: CGPoint,
                                         threshold: CGFloat = 8) -> Bool {
        guard translation.x.isFinite,
              translation.y.isFinite,
              threshold.isFinite,
              threshold >= 0 else {
            return false
        }

        return max(abs(translation.x), abs(translation.y)) >= threshold
    }

    static func centerByPanning(_ center: CGPoint,
                                translation: CGPoint,
                                pannableAxes: PannableAxes,
                                effectiveScale: CGFloat) -> CGPoint {
        guard effectiveScale.isFinite, effectiveScale > 0 else { return center }

        var result = center
        if pannableAxes.contains(.horizontal) {
            result.x -= translation.x / effectiveScale
        }
        if pannableAxes.contains(.vertical) {
            result.y -= translation.y / effectiveScale
        }
        return result
    }

    /// Returns the smallest center change that keeps the cursor outside an
    /// activation band at the visible edge. `edgeInset` is measured in screen
    /// points, so the interaction feels consistent at every zoom level.
    static func centerRevealingCursor(_ center: CGPoint,
                                      cursor: CGPoint,
                                      previousCursor: CGPoint? = nil,
                                      contentSize: CGSize,
                                      viewportSize: CGSize,
                                      effectiveScale: CGFloat,
                                      edgeInset: CGFloat = 48,
                                      requiresOutwardMovement: Bool = false) -> CGPoint {
        let axes = pannableAxes(contentSize: contentSize,
                                viewportSize: viewportSize,
                                effectiveScale: effectiveScale)
        guard !axes.isEmpty,
              cursor.x.isFinite,
              cursor.y.isFinite,
              edgeInset.isFinite,
              edgeInset >= 0 else {
            return center
        }

        var result = center

        if axes.contains(.horizontal) {
            let visibleHalfWidth = viewportSize.width / (2 * effectiveScale)
            let inset = min(edgeInset / effectiveScale, visibleHalfWidth)
            let visibleMinX = center.x - visibleHalfWidth
            let visibleMaxX = center.x + visibleHalfWidth
            let activationMinX = visibleMinX + inset
            let activationMaxX = visibleMaxX - inset

            if cursor.x <= activationMinX,
               isMovingOutward(current: cursor.x,
                               previous: previousCursor?.x,
                               towardMinimum: true,
                               required: requiresOutwardMovement) {
                result.x = cursor.x + visibleHalfWidth - inset
            } else if cursor.x >= activationMaxX,
                      isMovingOutward(current: cursor.x,
                                      previous: previousCursor?.x,
                                      towardMinimum: false,
                                      required: requiresOutwardMovement) {
                result.x = cursor.x - visibleHalfWidth + inset
            }
        }

        if axes.contains(.vertical) {
            let visibleHalfHeight = viewportSize.height / (2 * effectiveScale)
            let inset = min(edgeInset / effectiveScale, visibleHalfHeight)
            let visibleMinY = center.y - visibleHalfHeight
            let visibleMaxY = center.y + visibleHalfHeight
            let activationMinY = visibleMinY + inset
            let activationMaxY = visibleMaxY - inset

            if cursor.y <= activationMinY,
               isMovingOutward(current: cursor.y,
                               previous: previousCursor?.y,
                               towardMinimum: true,
                               required: requiresOutwardMovement) {
                result.y = cursor.y + visibleHalfHeight - inset
            } else if cursor.y >= activationMaxY,
                      isMovingOutward(current: cursor.y,
                                      previous: previousCursor?.y,
                                      towardMinimum: false,
                                      required: requiresOutwardMovement) {
                result.y = cursor.y - visibleHalfHeight + inset
            }
        }

        return result
    }

    private static func isMovingOutward(current: CGFloat,
                                         previous: CGFloat?,
                                         towardMinimum: Bool,
                                         required: Bool) -> Bool {
        guard required else { return true }
        guard let previous, previous.isFinite else { return false }

        return towardMinimum ? current < previous : current > previous
    }
}

private extension CGSize {
    var isUsable: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
