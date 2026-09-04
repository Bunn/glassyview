import AppKit
import CoreGraphics

/// Builds mouse events without posting them. Synthetic Quartz events do not
/// infer repeated clicks from successive button-down/button-up pairs.
struct RemoteMouseEventBuilder {
    private struct Click {
        let button: CGMouseButton
        let location: CGPoint
        let timestamp: TimeInterval
        let count: Int64
    }

    // Quartz locations are in display points. Allow small pointer/touch jitter
    // without grouping clicks aimed at different items or following a drag.
    private let maximumClickDistance: CGFloat = 8
    private var lastClick: Click?
    private var pressedClickCounts: [CGMouseButton.RawValue: Int64] = [:]

    mutating func makeEvent(
        type: CGEventType,
        location: CGPoint,
        button: CGMouseButton,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime,
        doubleClickInterval: TimeInterval = NSEvent.doubleClickInterval
    ) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: nil,
                                  mouseType: type,
                                  mouseCursorPosition: location,
                                  mouseButton: button) else { return nil }

        if let lastClick,
           hypot(location.x - lastClick.location.x,
                 location.y - lastClick.location.y) > maximumClickDistance {
            resetClickSequence()
        }

        let clickCount: Int64
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if let lastClick,
               lastClick.button == button,
               timestamp >= lastClick.timestamp,
               timestamp - lastClick.timestamp <= doubleClickInterval {
                clickCount = lastClick.count + 1
            } else {
                clickCount = 1
            }
            lastClick = Click(button: button,
                              location: location,
                              timestamp: timestamp,
                              count: clickCount)
            pressedClickCounts[button.rawValue] = clickCount

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            clickCount = pressedClickCounts.removeValue(forKey: button.rawValue) ?? 0

        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            clickCount = pressedClickCounts[button.rawValue] ?? 0

        default:
            clickCount = 0
        }

        // AppKit reads this field on both down and up. Posting a second plain
        // CGEvent does not increase its default single-click count.
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        return event
    }

    /// A new display or input session cannot continue the previous click series.
    /// Preserve any held button's count until its matching release is emitted.
    mutating func resetClickSequence() {
        lastClick = nil
    }
}
