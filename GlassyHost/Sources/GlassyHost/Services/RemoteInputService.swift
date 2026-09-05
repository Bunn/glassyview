import ApplicationServices
import CoreGraphics
import Foundation

/// Injects authenticated Glassy Stream input into the selected capture display.
/// All mutable input state is serialized so button and modifier transitions stay
/// ordered even when Network.framework delivers messages rapidly.
final class RemoteInputService: @unchecked Sendable {
    private let queue: DispatchQueue
    private let clipboardPaste: HostClipboardPasteService
    private let accessibilityCheck: @Sendable () -> Bool

    private var selectedDisplayID: CGDirectDisplayID?
    private var isEnabled = false
    private var pressedButtons: HostProtocol.PointerButtonMask = []
    private var pressedModifierKeysyms: Set<UInt32> = []
    private var lastPointerLocation: CGPoint?
    private var mouseEventBuilder = RemoteMouseEventBuilder()

    init(inputQueue: DispatchQueue = DispatchQueue(
        label: "dev.bunn.glassydesk.host.remote-input",
        qos: .userInteractive
    ),
         clipboardPaste: HostClipboardPasteService = HostClipboardPasteService(),
         accessibilityCheck: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        queue = inputQueue
        self.clipboardPaste = clipboardPaste
        self.accessibilityCheck = accessibilityCheck
    }

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func setDisplayID(_ displayID: CGDirectDisplayID?) {
        queue.async { [weak self] in
            guard let self else { return }
            if selectedDisplayID != displayID {
                mouseEventBuilder.resetClickSequence()
            }
            selectedDisplayID = displayID
        }
    }

    func setEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isEnabled = enabled
            if !enabled {
                self.releasePressedInputLocked()
            }
        }
    }

    func handle(_ event: HostProtocol.RemoteInputEvent) {
        queue.async { [weak self] in
            guard let self, self.isEnabled, self.accessibilityCheck() else { return }
            switch event {
            case .pointer(let input):
                handlePointer(input)
            case .scroll(let input):
                handleScroll(input)
            case .key(let input):
                handleKey(input)
            case .text(let input):
                handleText(input)
            case .clipboardPaste(let text):
                clipboardPaste.paste(text)
            }
        }
    }

    /// Prevents a disconnected client from leaving a synthetic button or
    /// modifier logically pressed on the Mac. Returning is a barrier: all
    /// earlier input and its reset have completed before revocation can report
    /// success or a replacement transport can submit input.
    func releasePressedInput() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            releasePressedInputLocked()
        }
    }

    static func point(normalizedX: UInt16,
                      normalizedY: UInt16,
                      in bounds: CGRect) -> CGPoint {
        let xFraction = CGFloat(normalizedX) / CGFloat(UInt16.max)
        let yFraction = CGFloat(normalizedY) / CGFloat(UInt16.max)
        let horizontalSpan = max(0, bounds.width - 1)
        let verticalSpan = max(0, bounds.height - 1)
        return CGPoint(x: bounds.minX + (horizontalSpan * xFraction),
                       y: bounds.minY + (verticalSpan * yFraction))
    }

    static func mappedKeyCode(forX11Keysym keysym: UInt32) -> CGKeyCode? {
        keyMapping(for: keysym)?.keyCode
    }

    static func requiredFlags(forX11Keysym keysym: UInt32) -> CGEventFlags? {
        keyMapping(for: keysym)?.requiredFlags
    }

    private func handlePointer(_ input: HostProtocol.PointerInput) {
        let bounds = displayBounds()
        guard bounds.width > 0, bounds.height > 0 else { return }

        let location = Self.point(normalizedX: input.normalizedX,
                                  normalizedY: input.normalizedY,
                                  in: bounds)
        lastPointerLocation = location

        let leftChanged = pressedButtons.contains(.left)
            != input.buttonMask.contains(.left)
        let rightChanged = pressedButtons.contains(.right)
            != input.buttonMask.contains(.right)

        if leftChanged {
            postMouse(
                type: input.buttonMask.contains(.left) ? .leftMouseDown : .leftMouseUp,
                location: location,
                button: .left
            )
        }
        if rightChanged {
            postMouse(
                type: input.buttonMask.contains(.right) ? .rightMouseDown : .rightMouseUp,
                location: location,
                button: .right
            )
        }

        if !leftChanged, !rightChanged {
            if input.buttonMask.contains(.left) {
                postMouse(type: .leftMouseDragged, location: location, button: .left)
            } else if input.buttonMask.contains(.right) {
                postMouse(type: .rightMouseDragged, location: location, button: .right)
            } else {
                postMouse(type: .mouseMoved, location: location, button: .left)
            }
        }

        pressedButtons = input.buttonMask
    }

    private func handleScroll(_ input: HostProtocol.ScrollInput) {
        let magnitude = Int32(input.steps)
        let vertical: Int32
        let horizontal: Int32
        switch input.direction {
        case .up:
            vertical = magnitude
            horizontal = 0
        case .down:
            vertical = -magnitude
            horizontal = 0
        case .left:
            vertical = 0
            horizontal = magnitude
        case .right:
            vertical = 0
            horizontal = -magnitude
        }

        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func handleKey(_ input: HostProtocol.KeyInput) {
        guard let mapping = Self.keyMapping(for: input.keysym) else {
            if let scalar = Self.unicodeScalar(fromX11Keysym: input.keysym), input.isDown {
                postUnicode(String(scalar), flags: currentModifierFlags)
            }
            return
        }

        if mapping.modifierFlag != nil {
            if input.isDown {
                pressedModifierKeysyms.insert(input.keysym)
            } else {
                pressedModifierKeysyms.remove(input.keysym)
            }
        }

        postKeyboard(
            keyCode: mapping.keyCode,
            isDown: input.isDown,
            flags: currentModifierFlags.union(mapping.requiredFlags)
        )
    }

    private func handleText(_ input: HostProtocol.TextInput) {
        let requestedFlags = Self.cgEventFlags(for: input.modifierMask)
        let flags = currentModifierFlags.union(requestedFlags)

        if input.text.unicodeScalars.count == 1,
           let scalar = input.text.unicodeScalars.first,
           scalar.value <= 0x7F,
           let mapping = Self.keyMapping(for: scalar.value) {
            let strokeFlags = flags.union(mapping.requiredFlags)
            postKeyboard(keyCode: mapping.keyCode,
                         isDown: true,
                         flags: strokeFlags)
            postKeyboard(keyCode: mapping.keyCode,
                         isDown: false,
                         flags: strokeFlags)
            return
        }

        postUnicode(input.text, flags: flags)
    }

    private func postUnicode(_ text: String, flags: CGEventFlags) {
        // CGEvent accepts UTF-16 code units. Small chunks avoid truncation in
        // older text-input paths while preserving surrogate pairs at the Swift
        // string boundary wherever possible.
        for chunk in text.chunksOfMaximumUTF16Length(20) {
            let units = Array(chunk.utf16)
            guard !units.isEmpty,
                  let keyDown = CGEvent(keyboardEventSource: nil,
                                        virtualKey: 0,
                                        keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil,
                                      virtualKey: 0,
                                      keyDown: false) else { continue }

            keyDown.flags = flags
            keyUp.flags = flags
            units.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: baseAddress
                )
            }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private func releasePressedInputLocked() {
        defer { mouseEventBuilder = RemoteMouseEventBuilder() }
        guard accessibilityCheck() else {
            pressedButtons = []
            pressedModifierKeysyms.removeAll()
            return
        }

        let location = lastPointerLocation ?? CGPoint(
            x: displayBounds().midX,
            y: displayBounds().midY
        )
        if pressedButtons.contains(.left) {
            postMouse(type: .leftMouseUp, location: location, button: .left)
        }
        if pressedButtons.contains(.right) {
            postMouse(type: .rightMouseUp, location: location, button: .right)
        }
        pressedButtons = []

        let pressed = pressedModifierKeysyms
        for keysym in pressed {
            pressedModifierKeysyms.remove(keysym)
            guard let mapping = Self.keyMapping(for: keysym) else { continue }
            postKeyboard(keyCode: mapping.keyCode,
                         isDown: false,
                         flags: currentModifierFlags)
        }
    }

    private var currentModifierFlags: CGEventFlags {
        pressedModifierKeysyms.reduce(into: CGEventFlags()) { flags, keysym in
            if let flag = Self.keyMapping(for: keysym)?.modifierFlag {
                flags.insert(flag)
            }
        }
    }

    private func displayBounds() -> CGRect {
        let displayID = selectedDisplayID ?? CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)
        return bounds.isEmpty ? CGDisplayBounds(CGMainDisplayID()) : bounds
    }

    private func postMouse(type: CGEventType,
                           location: CGPoint,
                           button: CGMouseButton) {
        guard let event = mouseEventBuilder.makeEvent(type: type,
                                                     location: location,
                                                     button: button) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func postKeyboard(keyCode: CGKeyCode,
                              isDown: Bool,
                              flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil,
                                  virtualKey: keyCode,
                                  keyDown: isDown) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}

private extension RemoteInputService {
    struct KeyMapping: Sendable {
        let keyCode: CGKeyCode
        var requiredFlags: CGEventFlags = []
        var modifierFlag: CGEventFlags?
    }

    static func cgEventFlags(for mask: HostProtocol.TextModifierMask) -> CGEventFlags {
        var flags: CGEventFlags = []
        if mask.contains(.command) { flags.insert(.maskCommand) }
        if mask.contains(.shift) { flags.insert(.maskShift) }
        if mask.contains(.option) { flags.insert(.maskAlternate) }
        if mask.contains(.control) { flags.insert(.maskControl) }
        return flags
    }

    static func unicodeScalar(fromX11Keysym keysym: UInt32) -> Unicode.Scalar? {
        guard keysym & 0xFF00_0000 == 0x0100_0000 else { return nil }
        return Unicode.Scalar(keysym & 0x00FF_FFFF)
    }

    // X11/RFB keysyms map to the physical ANSI virtual key used by Quartz.
    // Printable symbols include the shift required to produce that keysym.
    static func keyMapping(for keysym: UInt32) -> KeyMapping? {
        if let printable = printableASCIIKeyMapping(for: keysym) {
            return printable
        }

        return switch keysym {
        case 0x08, 0xFF08: KeyMapping(keyCode: 51) // Backspace
        case 0x09, 0xFF09: KeyMapping(keyCode: 48) // Tab
        case 0x0D, 0xFF0D: KeyMapping(keyCode: 36) // Return
        case 0x1B, 0xFF1B: KeyMapping(keyCode: 53) // Escape
        case 0xFF50: KeyMapping(keyCode: 115) // Home
        case 0xFF51: KeyMapping(keyCode: 123) // Left
        case 0xFF52: KeyMapping(keyCode: 126) // Up
        case 0xFF53: KeyMapping(keyCode: 124) // Right
        case 0xFF54: KeyMapping(keyCode: 125) // Down
        case 0xFF55: KeyMapping(keyCode: 116) // Page Up
        case 0xFF56: KeyMapping(keyCode: 121) // Page Down
        case 0xFF57: KeyMapping(keyCode: 119) // End
        case 0xFF63: KeyMapping(keyCode: 114) // Insert / Help
        case 0xFFFF: KeyMapping(keyCode: 117) // Forward Delete
        case 0xFF8D: KeyMapping(keyCode: 76) // Keypad Enter
        case 0xFFAA: KeyMapping(keyCode: 67) // Keypad Multiply
        case 0xFFAB: KeyMapping(keyCode: 69) // Keypad Add
        case 0xFFAD: KeyMapping(keyCode: 78) // Keypad Subtract
        case 0xFFAE: KeyMapping(keyCode: 65) // Keypad Decimal
        case 0xFFAF: KeyMapping(keyCode: 75) // Keypad Divide
        case 0xFFB0: KeyMapping(keyCode: 82)
        case 0xFFB1: KeyMapping(keyCode: 83)
        case 0xFFB2: KeyMapping(keyCode: 84)
        case 0xFFB3: KeyMapping(keyCode: 85)
        case 0xFFB4: KeyMapping(keyCode: 86)
        case 0xFFB5: KeyMapping(keyCode: 87)
        case 0xFFB6: KeyMapping(keyCode: 88)
        case 0xFFB7: KeyMapping(keyCode: 89)
        case 0xFFB8: KeyMapping(keyCode: 91)
        case 0xFFB9: KeyMapping(keyCode: 92)
        case 0xFFBE: KeyMapping(keyCode: 122) // F1
        case 0xFFBF: KeyMapping(keyCode: 120)
        case 0xFFC0: KeyMapping(keyCode: 99)
        case 0xFFC1: KeyMapping(keyCode: 118)
        case 0xFFC2: KeyMapping(keyCode: 96)
        case 0xFFC3: KeyMapping(keyCode: 97)
        case 0xFFC4: KeyMapping(keyCode: 98)
        case 0xFFC5: KeyMapping(keyCode: 100)
        case 0xFFC6: KeyMapping(keyCode: 101)
        case 0xFFC7: KeyMapping(keyCode: 109)
        case 0xFFC8: KeyMapping(keyCode: 103)
        case 0xFFC9: KeyMapping(keyCode: 111)
        case 0xFFCA: KeyMapping(keyCode: 105)
        case 0xFFCB: KeyMapping(keyCode: 107)
        case 0xFFCC: KeyMapping(keyCode: 113)
        case 0xFFCD: KeyMapping(keyCode: 106)
        case 0xFFCE: KeyMapping(keyCode: 64)
        case 0xFFCF: KeyMapping(keyCode: 79)
        case 0xFFD0: KeyMapping(keyCode: 80)
        case 0xFFD1: KeyMapping(keyCode: 90) // F20
        case 0xFFE1: KeyMapping(keyCode: 56, modifierFlag: .maskShift)
        case 0xFFE2: KeyMapping(keyCode: 60, modifierFlag: .maskShift)
        case 0xFFE3: KeyMapping(keyCode: 59, modifierFlag: .maskControl)
        case 0xFFE4: KeyMapping(keyCode: 62, modifierFlag: .maskControl)
        case 0xFFE5, 0xFFE6: KeyMapping(keyCode: 57) // Caps/Shift Lock
        case 0xFFE7, 0xFFEB: KeyMapping(keyCode: 55, modifierFlag: .maskCommand)
        case 0xFFE8, 0xFFEC: KeyMapping(keyCode: 54, modifierFlag: .maskCommand)
        case 0xFFE9: KeyMapping(keyCode: 58, modifierFlag: .maskAlternate)
        case 0xFFEA: KeyMapping(keyCode: 61, modifierFlag: .maskAlternate)
        default: nil
        }
    }

    static func printableASCIIKeyMapping(for keysym: UInt32) -> KeyMapping? {
        let shift: CGEventFlags = .maskShift
        return switch keysym {
        case 0x20: KeyMapping(keyCode: 49)
        case 0x61: KeyMapping(keyCode: 0)
        case 0x73: KeyMapping(keyCode: 1)
        case 0x64: KeyMapping(keyCode: 2)
        case 0x66: KeyMapping(keyCode: 3)
        case 0x68: KeyMapping(keyCode: 4)
        case 0x67: KeyMapping(keyCode: 5)
        case 0x7A: KeyMapping(keyCode: 6)
        case 0x78: KeyMapping(keyCode: 7)
        case 0x63: KeyMapping(keyCode: 8)
        case 0x76: KeyMapping(keyCode: 9)
        case 0x62: KeyMapping(keyCode: 11)
        case 0x71: KeyMapping(keyCode: 12)
        case 0x77: KeyMapping(keyCode: 13)
        case 0x65: KeyMapping(keyCode: 14)
        case 0x72: KeyMapping(keyCode: 15)
        case 0x79: KeyMapping(keyCode: 16)
        case 0x74: KeyMapping(keyCode: 17)
        case 0x31: KeyMapping(keyCode: 18)
        case 0x32: KeyMapping(keyCode: 19)
        case 0x33: KeyMapping(keyCode: 20)
        case 0x34: KeyMapping(keyCode: 21)
        case 0x36: KeyMapping(keyCode: 22)
        case 0x35: KeyMapping(keyCode: 23)
        case 0x3D: KeyMapping(keyCode: 24)
        case 0x39: KeyMapping(keyCode: 25)
        case 0x37: KeyMapping(keyCode: 26)
        case 0x2D: KeyMapping(keyCode: 27)
        case 0x38: KeyMapping(keyCode: 28)
        case 0x30: KeyMapping(keyCode: 29)
        case 0x5D: KeyMapping(keyCode: 30)
        case 0x6F: KeyMapping(keyCode: 31)
        case 0x75: KeyMapping(keyCode: 32)
        case 0x5B: KeyMapping(keyCode: 33)
        case 0x69: KeyMapping(keyCode: 34)
        case 0x70: KeyMapping(keyCode: 35)
        case 0x6C: KeyMapping(keyCode: 37)
        case 0x6A: KeyMapping(keyCode: 38)
        case 0x27: KeyMapping(keyCode: 39)
        case 0x6B: KeyMapping(keyCode: 40)
        case 0x3B: KeyMapping(keyCode: 41)
        case 0x5C: KeyMapping(keyCode: 42)
        case 0x2C: KeyMapping(keyCode: 43)
        case 0x2F: KeyMapping(keyCode: 44)
        case 0x6E: KeyMapping(keyCode: 45)
        case 0x6D: KeyMapping(keyCode: 46)
        case 0x2E: KeyMapping(keyCode: 47)
        case 0x60: KeyMapping(keyCode: 50)

        case 0x41: KeyMapping(keyCode: 0, requiredFlags: shift)
        case 0x53: KeyMapping(keyCode: 1, requiredFlags: shift)
        case 0x44: KeyMapping(keyCode: 2, requiredFlags: shift)
        case 0x46: KeyMapping(keyCode: 3, requiredFlags: shift)
        case 0x48: KeyMapping(keyCode: 4, requiredFlags: shift)
        case 0x47: KeyMapping(keyCode: 5, requiredFlags: shift)
        case 0x5A: KeyMapping(keyCode: 6, requiredFlags: shift)
        case 0x58: KeyMapping(keyCode: 7, requiredFlags: shift)
        case 0x43: KeyMapping(keyCode: 8, requiredFlags: shift)
        case 0x56: KeyMapping(keyCode: 9, requiredFlags: shift)
        case 0x42: KeyMapping(keyCode: 11, requiredFlags: shift)
        case 0x51: KeyMapping(keyCode: 12, requiredFlags: shift)
        case 0x57: KeyMapping(keyCode: 13, requiredFlags: shift)
        case 0x45: KeyMapping(keyCode: 14, requiredFlags: shift)
        case 0x52: KeyMapping(keyCode: 15, requiredFlags: shift)
        case 0x59: KeyMapping(keyCode: 16, requiredFlags: shift)
        case 0x54: KeyMapping(keyCode: 17, requiredFlags: shift)
        case 0x4F: KeyMapping(keyCode: 31, requiredFlags: shift)
        case 0x55: KeyMapping(keyCode: 32, requiredFlags: shift)
        case 0x49: KeyMapping(keyCode: 34, requiredFlags: shift)
        case 0x50: KeyMapping(keyCode: 35, requiredFlags: shift)
        case 0x4C: KeyMapping(keyCode: 37, requiredFlags: shift)
        case 0x4A: KeyMapping(keyCode: 38, requiredFlags: shift)
        case 0x4B: KeyMapping(keyCode: 40, requiredFlags: shift)
        case 0x4E: KeyMapping(keyCode: 45, requiredFlags: shift)
        case 0x4D: KeyMapping(keyCode: 46, requiredFlags: shift)
        case 0x21: KeyMapping(keyCode: 18, requiredFlags: shift)
        case 0x40: KeyMapping(keyCode: 19, requiredFlags: shift)
        case 0x23: KeyMapping(keyCode: 20, requiredFlags: shift)
        case 0x24: KeyMapping(keyCode: 21, requiredFlags: shift)
        case 0x5E: KeyMapping(keyCode: 22, requiredFlags: shift)
        case 0x25: KeyMapping(keyCode: 23, requiredFlags: shift)
        case 0x2B: KeyMapping(keyCode: 24, requiredFlags: shift)
        case 0x28: KeyMapping(keyCode: 25, requiredFlags: shift)
        case 0x26: KeyMapping(keyCode: 26, requiredFlags: shift)
        case 0x5F: KeyMapping(keyCode: 27, requiredFlags: shift)
        case 0x2A: KeyMapping(keyCode: 28, requiredFlags: shift)
        case 0x29: KeyMapping(keyCode: 29, requiredFlags: shift)
        case 0x7D: KeyMapping(keyCode: 30, requiredFlags: shift)
        case 0x7B: KeyMapping(keyCode: 33, requiredFlags: shift)
        case 0x22: KeyMapping(keyCode: 39, requiredFlags: shift)
        case 0x3A: KeyMapping(keyCode: 41, requiredFlags: shift)
        case 0x7C: KeyMapping(keyCode: 42, requiredFlags: shift)
        case 0x3C: KeyMapping(keyCode: 43, requiredFlags: shift)
        case 0x3F: KeyMapping(keyCode: 44, requiredFlags: shift)
        case 0x3E: KeyMapping(keyCode: 47, requiredFlags: shift)
        case 0x7E: KeyMapping(keyCode: 50, requiredFlags: shift)
        default: nil
        }
    }
}

private extension String {
    func chunksOfMaximumUTF16Length(_ maximumLength: Int) -> [Substring] {
        guard maximumLength > 0 else { return [] }
        var result: [Substring] = []
        var start = startIndex
        var cursor = start
        var currentLength = 0

        while cursor < endIndex {
            let next = index(after: cursor)
            let characterLength = self[cursor..<next].utf16.count
            if currentLength > 0, currentLength + characterLength > maximumLength {
                result.append(self[start..<cursor])
                start = cursor
                currentLength = 0
            }
            currentLength += characterLength
            cursor = next
        }
        if start < endIndex {
            result.append(self[start..<endIndex])
        }
        return result
    }
}
