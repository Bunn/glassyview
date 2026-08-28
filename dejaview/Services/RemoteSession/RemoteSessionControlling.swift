import Combine
import CoreGraphics
import RoyalVNCKit

protocol RemoteSessionInputControlling: AnyObject {
    var touchMode: RemoteTouchMode { get }
    var cursorLocation: CGPoint { get }

    func leftButtonDown(at point: CGPoint)
    func leftButtonUp(at point: CGPoint)
    func moveCursor(by delta: CGPoint, dragging: Bool)
    func moveCursor(to point: CGPoint, dragging: Bool)
    func clickAtCursor()
    func rightClick(at point: CGPoint)
    func rightClickAtCursor()
    func scroll(_ direction: RemoteScrollDirection, steps: UInt32)
    func pressAtCursor()
    func releaseAtCursor()
    func setModifier(_ modifier: RemoteModifierKey, isPressed: Bool)
    func releaseHeldModifiers()
    func sendText(_ text: String, modifiers: [VNCKeyCode])
    func sendKey(_ keyCode: VNCKeyCode, modifiers: [VNCKeyCode])
    func sendReturn()
}

protocol RemoteSessionControlling: ObservableObject, RemoteSessionInputControlling {
    var status: RemoteSessionStatus { get }

    /// Current framebuffer updates. Deliberately NOT part of
    /// `objectWillChange`: frames arrive at display rate, and invalidating
    /// SwiftUI for each one causes constant re-layout (which, among other
    /// things, makes presented menus flicker).
    var framebufferUpdatePublisher: AnyPublisher<RemoteFramebufferUpdate, Never> { get }
    var cursor: RemoteCursor? { get }
    var cursorPublisher: AnyPublisher<RemoteCursor?, Never> { get }
    var quality: RemoteSessionQuality { get }
    var supportedQualities: [RemoteSessionQuality] { get }
    var preferredFrameRate: RemoteFrameRate { get }
    var displays: [RemoteDisplay] { get }
    var displayOptions: [RemoteDisplayOption] { get }
    var displaySelection: RemoteDisplaySelection { get }
    var selectedDisplayFrame: CGRect? { get }

    func connect(host: String, port: UInt16, username: String, password: String)
    func disconnect()
    func reset()
    func applyPreferences(_ preferences: SessionPreferences)
    func setQuality(_ newQuality: RemoteSessionQuality)
    func setPreferredFrameRate(_ frameRate: RemoteFrameRate)
    func setDisplaySelection(_ selection: RemoteDisplaySelection)
    func toggleTouchMode()
    func retryConnect()
    func cancelReconnect()
    func updateNetworkPathStatus(_ status: NetworkPathStatus)

#if DEBUG
    func debugSimulateConnectionInterruption()
#endif
}

extension RemoteSessionInputControlling {
    func moveCursor(to point: CGPoint) {
        moveCursor(to: point, dragging: false)
    }

    func scroll(_ direction: RemoteScrollDirection) {
        scroll(direction, steps: 1)
    }

    func sendText(_ text: String) {
        sendText(text, modifiers: [])
    }

    func sendKey(_ keyCode: VNCKeyCode) {
        sendKey(keyCode, modifiers: [])
    }
}
