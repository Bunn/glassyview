import CoreGraphics

enum HostCursorPositionNormalizer {
    /// Maps a Quartz global cursor location into the same normalized coordinate
    /// space used by direct pointer input. The maximum display edges are
    /// exclusive because they belong to an adjacent display in Quartz space.
    static func normalize(
        _ location: CGPoint,
        in displayBounds: CGRect
    ) -> HostProtocol.CursorPosition? {
        guard location.x.isFinite,
              location.y.isFinite,
              displayBounds.origin.x.isFinite,
              displayBounds.origin.y.isFinite,
              displayBounds.width.isFinite,
              displayBounds.height.isFinite,
              displayBounds.width > 0,
              displayBounds.height > 0,
              location.x >= displayBounds.minX,
              location.x < displayBounds.maxX,
              location.y >= displayBounds.minY,
              location.y < displayBounds.maxY else { return nil }

        return HostProtocol.CursorPosition(
            normalizedX: normalizeCoordinate(
                location.x - displayBounds.minX,
                extent: displayBounds.width
            ),
            normalizedY: normalizeCoordinate(
                location.y - displayBounds.minY,
                extent: displayBounds.height
            )
        )
    }

    private static func normalizeCoordinate(
        _ offset: CGFloat,
        extent: CGFloat
    ) -> UInt16 {
        let pixelSpan = extent - 1
        guard pixelSpan > 0 else { return 0 }
        let fraction = min(max(offset / pixelSpan, 0), 1)
        return UInt16((fraction * CGFloat(UInt16.max)).rounded())
    }
}

struct HostCursorPositionTracker {
    enum Update: Equatable {
        case position(HostProtocol.CursorPosition)
        case unavailable
    }

    private var lastPosition: HostProtocol.CursorPosition?

    /// Returns a position only when it differs from the previous in-display
    /// sample. An absent or out-of-display sample resets deduplication so
    /// re-entering the captured display is always observable.
    mutating func update(
        for location: CGPoint?,
        in displayBounds: CGRect
    ) -> Update? {
        guard let location,
              let position = HostCursorPositionNormalizer.normalize(
                  location,
                  in: displayBounds
              ) else {
            guard lastPosition != nil else { return nil }
            lastPosition = nil
            return .unavailable
        }
        guard position != lastPosition else { return nil }
        lastPosition = position
        return .position(position)
    }
}
