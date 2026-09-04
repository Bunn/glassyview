import AppKit
import CoreGraphics
import Testing
@testable import GlassyHost

@Test("Two rapid remote taps produce a double click in AppKit", arguments: [CGMouseButton.left, .right])
func remoteMouseDoubleClick(button: CGMouseButton) throws {
    var mouse = RemoteMouseEventBuilder()
    let down: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
    let up: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
    let samples: [(CGEventType, TimeInterval, Int64)] = [
        (down, 10, 1),
        (up, 10.05, 1),
        (down, 10.2, 2),
        (up, 10.25, 2),
    ]

    for (type, timestamp, expectedClickCount) in samples {
        let generatedEvent = mouse.makeEvent(
            type: type,
            location: CGPoint(x: 100, y: 200),
            button: button,
            timestamp: timestamp,
            doubleClickInterval: 0.5
        )
        let event = try #require(generatedEvent)
        #expect(event.type == type)
        #expect(event.location == CGPoint(x: 100, y: 200))
        #expect(event.getIntegerValueField(.mouseEventButtonNumber) == Int64(button.rawValue))
        #expect(event.getIntegerValueField(.mouseEventClickState) == expectedClickCount)
        // Verify the click count the receiving Mac app reads, without posting
        // real input or requiring Accessibility access in the test runner.
        let appKitEvent = try #require(NSEvent(cgEvent: event))
        #expect(appKitEvent.clickCount == Int(expectedClickCount))
    }
}

@Test("Remote double clicks respect the host's configured interval", arguments: [0.2, 0.6])
func remoteMouseDoubleClickInterval(interval: TimeInterval) throws {
    var mouse = RemoteMouseEventBuilder()
    let secondCount: Int64 = interval == 0.2 ? 1 : 2
    try expectMouseEvents(&mouse, interval: interval, samples: [
        MouseSample(type: .leftMouseDown, time: 10, count: 1),
        MouseSample(type: .leftMouseUp, time: 10.05, count: 1),
        MouseSample(type: .leftMouseDown, time: 10.35, count: secondCount),
        MouseSample(type: .leftMouseUp, time: 10.4, count: secondCount),
    ])
}

@Test("Small pointer jitter preserves double and triple clicks")
func remoteMouseClickJitterAndTripleClick() throws {
    var mouse = RemoteMouseEventBuilder()
    let nearby = CGPoint(x: 103, y: 204)
    try expectMouseEvents(&mouse, samples: [
        MouseSample(type: .leftMouseDown, time: 10, count: 1),
        MouseSample(type: .leftMouseUp, time: 10.05, count: 1),
        MouseSample(type: .mouseMoved, time: 10.1, count: 0, location: nearby),
        MouseSample(type: .leftMouseDown, time: 10.2, count: 2, location: nearby),
        MouseSample(type: .leftMouseUp, time: 10.25, count: 2, location: nearby),
        MouseSample(type: .leftMouseDown, time: 10.4, count: 3),
        MouseSample(type: .leftMouseUp, time: 10.45, count: 3),
    ])
}

@Test("Rapid clicks on separate targets stay single clicks")
func remoteMouseSeparateTargets() throws {
    var mouse = RemoteMouseEventBuilder()
    let elsewhere = CGPoint(x: 140, y: 200)
    try expectMouseEvents(&mouse, samples: [
        MouseSample(type: .leftMouseDown, time: 10, count: 1),
        MouseSample(type: .leftMouseUp, time: 10.05, count: 1),
        MouseSample(type: .leftMouseDown, time: 10.2, count: 1, location: elsewhere),
        MouseSample(type: .leftMouseUp, time: 10.25, count: 1, location: elsewhere),
    ])
}

@Test("Moving away and back breaks the click sequence")
func remoteMouseMovementBreaksClickSequence() throws {
    var mouse = RemoteMouseEventBuilder()
    try expectMouseEvents(&mouse, samples: [
        MouseSample(type: .leftMouseDown, time: 10, count: 1),
        MouseSample(type: .leftMouseUp, time: 10.05, count: 1),
        MouseSample(type: .mouseMoved, time: 10.1, count: 0, location: CGPoint(x: 100, y: 240)),
        MouseSample(type: .mouseMoved, time: 10.15, count: 0),
        MouseSample(type: .leftMouseDown, time: 10.2, count: 1),
        MouseSample(type: .leftMouseUp, time: 10.25, count: 1),
    ])
}

@Test("Dragging preserves the held click count and breaks the next click sequence")
func remoteMouseDragBreaksClickSequence() throws {
    var mouse = RemoteMouseEventBuilder()
    try expectMouseEvents(&mouse, samples: [
        MouseSample(type: .leftMouseDown, time: 10, count: 1),
        MouseSample(type: .leftMouseUp, time: 10.05, count: 1),
        MouseSample(type: .leftMouseDown, time: 10.2, count: 2),
        MouseSample(type: .leftMouseDragged, time: 10.25, count: 2, location: CGPoint(x: 140, y: 200)),
        MouseSample(type: .leftMouseDragged, time: 10.3, count: 2),
        MouseSample(type: .leftMouseUp, time: 10.35, count: 2),
        MouseSample(type: .leftMouseDown, time: 10.4, count: 1),
        MouseSample(type: .leftMouseUp, time: 10.45, count: 1),
    ])
}

@Test("A late mouse-up retains its press count without extending the double-click window")
func remoteMouseLongPress() throws {
    var mouse = RemoteMouseEventBuilder()
    try expectMouseEvents(&mouse, samples: [
        MouseSample(type: .leftMouseDown, time: 10, count: 1),
        MouseSample(type: .leftMouseUp, time: 10.8, count: 1),
        MouseSample(type: .leftMouseDown, time: 10.9, count: 1),
        MouseSample(type: .leftMouseUp, time: 10.95, count: 1),
    ])
}

@Test("Changing buttons starts a new sequence and preserves each held button's release")
func remoteMouseButtonChanges() throws {
    var mouse = RemoteMouseEventBuilder()
    try expectMouseEvents(&mouse, samples: [
        MouseSample(type: .leftMouseDown, time: 10, count: 1),
        MouseSample(type: .leftMouseUp, time: 10.05, count: 1),
        MouseSample(type: .leftMouseDown, time: 10.1, count: 2),
        MouseSample(type: .rightMouseDown, time: 10.15, count: 1, button: .right),
        MouseSample(type: .leftMouseUp, time: 10.2, count: 2),
        MouseSample(type: .rightMouseUp, time: 10.25, count: 1, button: .right),
        MouseSample(type: .leftMouseDown, time: 10.3, count: 1),
        MouseSample(type: .leftMouseUp, time: 10.35, count: 1),
    ])
}

@Test("Resetting a click sequence keeps the pending release and starts the next click at one")
func remoteMouseClickSequenceReset() throws {
    var mouse = RemoteMouseEventBuilder()
    try expectMouseEvents(&mouse, samples: [
        MouseSample(type: .leftMouseDown, time: 10, count: 1),
        MouseSample(type: .leftMouseUp, time: 10.05, count: 1),
        MouseSample(type: .leftMouseDown, time: 10.2, count: 2),
    ])
    mouse.resetClickSequence()
    try expectMouseEvents(&mouse, samples: [
        MouseSample(type: .leftMouseUp, time: 10.25, count: 2),
        MouseSample(type: .leftMouseDown, time: 10.4, count: 1),
        MouseSample(type: .leftMouseUp, time: 10.45, count: 1),
    ])
}

private struct MouseSample {
    let type: CGEventType
    let time: TimeInterval
    let count: Int64
    var location = CGPoint(x: 100, y: 200)
    var button: CGMouseButton = .left
}

private func expectMouseEvents(
    _ mouse: inout RemoteMouseEventBuilder,
    interval: TimeInterval = 0.5,
    samples: [MouseSample]
) throws {
    for sample in samples {
        let generatedEvent = mouse.makeEvent(type: sample.type,
                                             location: sample.location,
                                             button: sample.button,
                                             timestamp: sample.time,
                                             doubleClickInterval: interval)
        let event = try #require(generatedEvent)
        #expect(event.type == sample.type)
        #expect(event.location == sample.location)
        #expect(event.getIntegerValueField(.mouseEventButtonNumber) == Int64(sample.button.rawValue))
        #expect(event.getIntegerValueField(.mouseEventClickState) == sample.count)
        if [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(sample.type) {
            let appKitEvent = try #require(NSEvent(cgEvent: event))
            #expect(appKitEvent.clickCount == Int(sample.count))
        }
    }
}
