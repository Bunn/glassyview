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

    /// Clamps the presentation without replacing the user's content anchor.
    /// Keeping the anchor separately lets a fold/rotation temporarily fit one
    /// axis, then restore that axis when the viewport becomes narrow again.
    static func clampedCenter(_ center: CGPoint,
                              contentSize: CGSize,
                              viewportSize: CGSize,
                              effectiveScale: CGFloat) -> CGPoint {
        guard contentSize.isUsable,
              viewportSize.isUsable,
              effectiveScale.isFinite,
              effectiveScale > 0 else { return center }

        func coordinate(_ value: CGFloat, contentLength: CGFloat, viewportLength: CGFloat) -> CGFloat {
            guard contentLength * effectiveScale > viewportLength else {
                return contentLength / 2
            }
            let halfVisibleLength = viewportLength / (2 * effectiveScale)
            let value = value.isFinite ? value : contentLength / 2
            return min(max(value, halfVisibleLength), contentLength - halfVisibleLength)
        }

        return CGPoint(x: coordinate(center.x, contentLength: contentSize.width,
                                     viewportLength: viewportSize.width),
                       y: coordinate(center.y, contentLength: contentSize.height,
                                     viewportLength: viewportSize.height))
    }

    static func contentFrame(contentSize: CGSize,
                             viewportBounds: CGRect,
                             effectiveScale: CGFloat,
                             center: CGPoint) -> CGRect {
        guard contentSize.isUsable,
              viewportBounds.size.isUsable,
              viewportBounds.origin.x.isFinite,
              viewportBounds.origin.y.isFinite,
              effectiveScale.isFinite,
              effectiveScale > 0 else { return .zero }

        let center = clampedCenter(center, contentSize: contentSize,
                                   viewportSize: viewportBounds.size,
                                   effectiveScale: effectiveScale)
        let renderedSize = CGSize(width: contentSize.width * effectiveScale,
                                  height: contentSize.height * effectiveScale)
        guard renderedSize.isUsable else { return .zero }
        return CGRect(x: viewportBounds.midX - center.x * effectiveScale,
                      y: viewportBounds.midY - center.y * effectiveScale,
                      width: renderedSize.width, height: renderedSize.height)
    }

    /// Maps against the frame that is actually displayed, including its local
    /// origin and a selected remote display's nonzero framebuffer origin.
    static func framebufferPoint(for point: CGPoint,
                                 contentFrame: CGRect,
                                 sourceFrame: CGRect) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite,
              contentFrame.size.isUsable, sourceFrame.size.isUsable,
              contentFrame.origin.x.isFinite, contentFrame.origin.y.isFinite,
              sourceFrame.origin.x.isFinite, sourceFrame.origin.y.isFinite else { return nil }

        let x = (point.x - contentFrame.minX) / contentFrame.width
        let y = (point.y - contentFrame.minY) / contentFrame.height
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: sourceFrame.minX + x * sourceFrame.width,
                       y: sourceFrame.minY + y * sourceFrame.height)
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
