import Combine
import CoreGraphics
import RoyalVNCKit

protocol RemoteSessionInputControlling: AnyObject {
    var touchMode: RemoteTouchMode { get }
    var cursorLocation: CGPoint { get }
    var supportsClipboardPaste: Bool { get }

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
    func pasteText(_ text: String)
}

protocol RemoteSessionControlling: ObservableObject, RemoteSessionInputControlling {
    var status: RemoteSessionStatus { get }
    var clipboardPasteError: String? { get }
    func clearClipboardPasteError()

    /// The connected Mac can share its clipboard with this device.
    var supportsMacClipboard: Bool { get }
    /// Text copied on the Mac goes to this device's clipboard without asking.
    var followsMacClipboard: Bool { get }
    /// What just happened with the Mac's clipboard, for a brief confirmation.
    var macClipboardNotice: MacClipboardNotice? { get }
    func copyMacClipboard()
    func setFollowsMacClipboard(_ follows: Bool)
    func clearMacClipboardNotice()

    /// Transfers for this session, when its transport supports files.
    var fileTransferCenter: FileTransferCenter? { get }
    /// The connected Mac currently accepts files from this device.
    var supportsFileTransfer: Bool { get }

    /// The connected Mac can cover its screen while this device controls it.
    var supportsCurtainMode: Bool { get }
    /// This device wants Curtain Mode; reapplied after reconnecting.
    var isCurtainModeRequested: Bool { get }
    /// Explains a Curtain Mode request the Mac could not fully honor.
    var curtainModeMessage: String? { get }
    func setCurtainModeRequested(_ requested: Bool)
    func clearCurtainModeMessage()

    /// Current framebuffer updates. Deliberately NOT part of
    /// `objectWillChange`: frames arrive at display rate, and invalidating
    /// SwiftUI for each one causes constant re-layout (which, among other
    /// things, makes presented menus flicker).
    var framebufferUpdatePublisher: AnyPublisher<RemoteFramebufferUpdate, Never> { get }
    var cursor: RemoteCursor? { get }
    var cursorPublisher: AnyPublisher<RemoteCursor?, Never> { get }
    var cursorLocationPublisher: AnyPublisher<CGPoint, Never> { get }
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
    // Standard VNC has no explicit clipboard-write API in RoyalVNC. Keep its
    // automatic clipboard monitor disabled; only capable transports opt in.
    var supportsClipboardPaste: Bool { false }
    func pasteText(_ text: String) {}

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

extension RemoteSessionControlling {
    var clipboardPasteError: String? { nil }
    func clearClipboardPasteError() {}
    // Standard VNC doesn't share the Mac's clipboard.
    var supportsMacClipboard: Bool { false }
    var followsMacClipboard: Bool { false }
    var macClipboardNotice: MacClipboardNotice? { nil }
    func copyMacClipboard() {}
    func setFollowsMacClipboard(_ follows: Bool) {}
    func clearMacClipboardNotice() {}
    // Standard VNC has no file transfer.
    var fileTransferCenter: FileTransferCenter? { nil }
    var supportsFileTransfer: Bool { false }
    // Standard VNC cannot cover the Mac's screen.
    var supportsCurtainMode: Bool { false }
    var isCurtainModeRequested: Bool { false }
    var curtainModeMessage: String? { nil }
    func setCurtainModeRequested(_ requested: Bool) {}
    func clearCurtainModeMessage() {}
}
