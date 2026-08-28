import CoreGraphics
import Testing
@testable import GlassyHost

@Test("Cursor positions normalize across offset display bounds")
func cursorPositionNormalization() {
    let bounds = CGRect(x: -1_920, y: 100, width: 1_920, height: 1_080)

    #expect(
        HostCursorPositionNormalizer.normalize(
            CGPoint(x: bounds.minX, y: bounds.minY),
            in: bounds
        ) == HostProtocol.CursorPosition(normalizedX: .min, normalizedY: .min)
    )
    #expect(
        HostCursorPositionNormalizer.normalize(
            CGPoint(x: bounds.maxX - 1, y: bounds.maxY - 1),
            in: bounds
        ) == HostProtocol.CursorPosition(normalizedX: .max, normalizedY: .max)
    )
}

@Test("Cursor normalization rejects locations outside the captured display")
func cursorPositionOutsideDisplay() {
    let bounds = CGRect(x: 50, y: -200, width: 100, height: 80)

    for location in [
        CGPoint(x: bounds.minX - 1, y: bounds.midY),
        CGPoint(x: bounds.maxX, y: bounds.midY),
        CGPoint(x: bounds.midX, y: bounds.minY - 1),
        CGPoint(x: bounds.midX, y: bounds.maxY)
    ] {
        #expect(HostCursorPositionNormalizer.normalize(location, in: bounds) == nil)
    }
    #expect(
        HostCursorPositionNormalizer.normalize(
            CGPoint(x: bounds.minX, y: bounds.minY),
            in: .zero
        ) == nil
    )
}

@Test("Cursor tracker deduplicates until the cursor leaves and re-enters")
func cursorPositionDeduplication() throws {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let location = CGPoint(x: 25, y: 75)
    var tracker = HostCursorPositionTracker()

    let first = try #require(
        HostCursorPositionNormalizer.normalize(location, in: bounds)
    )
    #expect(tracker.update(for: location, in: bounds) == .position(first))
    #expect(tracker.update(for: location, in: bounds) == nil)
    #expect(
        tracker.update(
            for: CGPoint(x: bounds.maxX, y: location.y),
            in: bounds
        ) == .unavailable
    )
    #expect(tracker.update(for: nil, in: bounds) == nil)
    #expect(tracker.update(for: location, in: bounds) == .position(first))
}
