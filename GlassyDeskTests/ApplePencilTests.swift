import CoreGraphics
import Foundation
import Testing
import UIKit
import RoyalVNCKit
@testable import GlassyDesk

@MainActor
struct ApplePencilTests {
    @Test(arguments: [RemoteTouchMode.direct, .trackpad])
    func pencilPressesExactlyWhereItTouchesWithoutDelay(mode: RemoteTouchMode) throws {
        let (view, session) = try makeView(touchMode: mode)
        let start = CGPoint(x: view.bounds.midX - 40, y: view.bounds.midY)
        let expected = try #require(view.debugFramebufferPoint(for: start))

        view.debugBeginSingleTouch(at: start, timestamp: 1, isPencil: true)
        // No debounce or long-press wait: the press is already sent.
        #expect(session.events == [.down(expected)])
        #expect(view.debugPencilTouchActive)

        let end = CGPoint(x: view.bounds.midX + 40, y: view.bounds.midY)
        view.debugEndPencilTouch(at: end, timestamp: 1.4)
        #expect(session.events == [.down(expected), .up(try #require(view.debugFramebufferPoint(for: end)))])
        #expect(!view.debugPencilTouchActive)
    }

    @Test
    func doubleTapActionsUseTheHoverLocation() throws {
        let (view, session) = try makeView(touchMode: .trackpad)
        let hover = CGPoint(x: view.bounds.midX, y: view.bounds.midY + 30)
        let point = try #require(view.debugFramebufferPoint(for: hover))

        view.debugPerformPencilShortcut(.secondaryClick, hoverLocation: hover)
        view.debugPerformPencilShortcut(.undo, hoverLocation: hover)
        view.debugPerformPencilShortcut(.escape, hoverLocation: nil)
        view.debugPerformPencilShortcut(.nothing, hoverLocation: hover)
        #expect(session.events == [.rightClick(point), .text("z"), .key])
        #expect(PencilShortcutAction.undo.command == .commandShortcut(character: "z"))
        #expect(PencilShortcutAction.escape.command == .escapeKey)
        #expect(PencilShortcutAction.nothing.command == .none)

        // Without a hover or recent stroke, the click lands at the cursor.
        let (unplaced, unplacedSession) = try makeView(touchMode: .trackpad)
        unplaced.debugPerformPencilShortcut(.secondaryClick, hoverLocation: nil)
        #expect(unplacedSession.events == [.rightClickAtCursor])
    }

    @Test
    func shortcutPreferenceDefaultsToSecondaryClickAndPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "ApplePencilTests.\(UUID().uuidString)"))
        #expect(PencilShortcutAction.current(in: defaults) == .secondaryClick)
        defaults.set(PencilShortcutAction.escape.rawValue, forKey: PencilShortcutAction.preferenceKey)
        #expect(PencilShortcutAction.current(in: defaults) == .escape)
        defaults.set("unknown", forKey: PencilShortcutAction.preferenceKey)
        #expect(PencilShortcutAction.current(in: defaults) == .secondaryClick)
    }

    // MARK: - Fixtures

    private func makeView(touchMode: RemoteTouchMode) throws -> (RemoteDesktopView<VNCSession>.ScreenView, RecordingSession) {
        let session = RecordingSession(touchMode: touchMode)
        let view = RemoteDesktopView<VNCSession>.ScreenView(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        view.session = session
        view.setTouchModeOverride(nil)
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        view.display(framebufferUpdate: RemoteFramebufferUpdate(image: try #require(context.makeImage()),
                                                               imageSize: CGSize(width: 2_048, height: 1_536),
                                                               dirtyRect: nil))
        view.layoutIfNeeded()
        return (view, session)
    }

    private final class RecordingSession: RemoteSessionInputControlling {
        enum Event: Equatable {
            case down(CGPoint), up(CGPoint), rightClick(CGPoint), rightClickAtCursor
            // VNCKeyCode values stay unread: RoyalVNCKit is linked into the app only.
            case text(String), key
        }

        let touchMode: RemoteTouchMode
        var cursorLocation = CGPoint(x: 1_024, y: 768)
        private(set) var events: [Event] = []

        init(touchMode: RemoteTouchMode) { self.touchMode = touchMode }

        func leftButtonDown(at point: CGPoint) {
            if events.last != .down(point) { events.append(.down(point)) }
            cursorLocation = point
        }
        func leftButtonUp(at point: CGPoint) {
            events.append(.up(point))
            cursorLocation = point
        }
        func moveCursor(by delta: CGPoint, dragging: Bool) {}
        func moveCursor(to point: CGPoint, dragging: Bool) { cursorLocation = point }
        func clickAtCursor() {}
        func rightClick(at point: CGPoint) { events.append(.rightClick(point)) }
        func rightClickAtCursor() { events.append(.rightClickAtCursor) }
        func scroll(_ direction: RemoteScrollDirection, steps: UInt32) {}
        func pressAtCursor() {}
        func releaseAtCursor() {}
        func setModifier(_ modifier: RemoteModifierKey, isPressed: Bool) {}
        func releaseHeldModifiers() {}
        func sendText(_ text: String, modifiers: [VNCKeyCode]) { events.append(.text(text)) }
        func sendKey(_ keyCode: VNCKeyCode, modifiers: [VNCKeyCode]) { events.append(.key) }
        func sendReturn() {}
    }
}
