import CoreGraphics

/// Posts remote input with a marker so Curtain Mode can tell it apart from
/// the Mac's own keyboard, mouse, and trackpad.
enum HostSyntheticInput {
    /// "GLSY". Carried in `kCGEventSourceUserData`, which macOS preserves for
    /// event taps at the HID location where these events are posted.
    static let marker: Int64 = 0x474C_5359

    static func post(_ event: CGEvent) {
        mark(event)
        event.post(tap: .cghidEventTap)
    }

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}
