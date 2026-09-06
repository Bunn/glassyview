import AppKit
import Testing
@testable import GlassyHost

@Test("Typed capitals and shifted punctuation reach Quartz and AppKit unchanged",
      arguments: ["d", "D", "!", "@", "_", "?", "{"])
@MainActor
func remoteInputTypedCharacters(text: String) throws {
    let events = keyboardEvents(for: [.text(.init(modifierMask: [], text: text))])
    #expect(events.count == 2)
    for event in events {
        #expect(keyboardText(event) == text)
        let appKitEvent = try #require(NSEvent(cgEvent: event))
        #expect(appKitEvent.characters == text)
    }
}

@Test("Shift applies to text modifiers and held modifier key events", arguments: [UInt32(0xFFE1), 0xFFE2])
@MainActor
func remoteInputShiftedText(shiftKeysym: UInt32) throws {
    let transient = keyboardEvents(for: [.text(.init(modifierMask: .shift, text: "d"))])
    let held = keyboardEvents(for: [
        .key(.init(keysym: shiftKeysym, isDown: true)),
        .text(.init(modifierMask: [], text: "d")),
        .key(.init(keysym: shiftKeysym, isDown: false)),
        .text(.init(modifierMask: [], text: "d")),
    ])
    #expect(transient.count == 2)
    for event in transient + held.filter({ $0.type == .keyDown || $0.type == .keyUp }).prefix(2) {
        #expect(event.flags.contains(.maskShift))
        #expect(keyboardText(event) == "D")
        #expect(try #require(NSEvent(cgEvent: event)).characters == "D")
    }
    #expect(held.count == 6)
    for event in held.suffix(2) {
        #expect(!event.flags.contains(.maskShift))
        #expect(keyboardText(event) == "d")
    }
}

@Test("Printable keysyms preserve capitals on key down and key up")
@MainActor
func remoteInputShiftedKeysym() {
    let events = keyboardEvents(for: [
        .key(.init(keysym: 0x44, isDown: true)),
        .key(.init(keysym: 0x44, isDown: false)),
    ])
    #expect(events.map(\.type) == [.keyDown, .keyUp])
    for event in events {
        #expect(event.getIntegerValueField(.keyboardEventKeycode) == 2)
        #expect(event.flags.contains(.maskShift))
        #expect(keyboardText(event) == "D")
    }
}

@Test("Shortcut characters retain AppKit's unmodified key for Command, Control, and Option",
      arguments: [HostProtocol.TextModifierMask.command, .control, .option,
                  [.command, .shift], [.control, .shift], [.option, .shift]])
@MainActor
func remoteInputShortcutCharacters(modifiers: HostProtocol.TextModifierMask) throws {
    let events = keyboardEvents(for: [.text(.init(modifierMask: modifiers, text: "d"))])
    #expect(events.count == 2)
    for event in events {
        let appKitEvent = try #require(NSEvent(cgEvent: event))
        #expect(appKitEvent.keyCode == 2)
        #expect(appKitEvent.modifierFlags.contains(.command) == modifiers.contains(.command))
        #expect(appKitEvent.modifierFlags.contains(.control) == modifiers.contains(.control))
        #expect(appKitEvent.modifierFlags.contains(.option) == modifiers.contains(.option))
        #expect(appKitEvent.modifierFlags.contains(.shift) == modifiers.contains(.shift))
        #expect(appKitEvent.charactersIgnoringModifiers == (modifiers.contains(.shift) ? "D" : "d"))
    }
}

@Test("Shift-arrow keeps its navigation key and revocation releases Shift")
@MainActor
func remoteInputShiftedNavigation() throws {
    let events = keyboardEvents(for: [
        .key(.init(keysym: 0xFFE1, isDown: true)),
        .key(.init(keysym: 0xFF51, isDown: true)),
        .key(.init(keysym: 0xFF51, isDown: false)),
    ])
    #expect(events.map(\.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
    for event in events.filter({ $0.type == .keyDown || $0.type == .keyUp }) {
        let appKitEvent = try #require(NSEvent(cgEvent: event))
        #expect(appKitEvent.keyCode == 123)
        #expect(appKitEvent.modifierFlags.contains(.shift))
        #expect(appKitEvent.characters == String(Unicode.Scalar(NSLeftArrowFunctionKey)!))
    }
    #expect(try #require(events.last).flags.isEmpty)
}

@Test("Unicode text still reaches the host without ASCII key translation")
func remoteInputUnicodeText() {
    let text = "Café 👋"
    let events = keyboardEvents(for: [.text(.init(modifierMask: [], text: text))])
    #expect(events.map(\.type) == [.keyDown, .keyUp])
    #expect(events.filter { $0.type == .keyDown }.map(keyboardText) == [text])
}

private func keyboardEvents(for inputs: [HostProtocol.RemoteInputEvent]) -> [CGEvent] {
    let recorder = KeyboardEventRecorder()
    let service = RemoteInputService(accessibilityCheck: { true },
                                     postKeyboardEvent: { recorder.append($0) })
    service.setEnabled(true)
    for input in inputs {
        service.handle(input)
    }
    service.releasePressedInput()
    return recorder.events
}

private func keyboardText(_ event: CGEvent) -> String {
    var units = [UniChar](repeating: 0, count: 20)
    var length = 0
    event.keyboardGetUnicodeString(maxStringLength: units.count,
                                  actualStringLength: &length,
                                  unicodeString: &units)
    return String(utf16CodeUnits: units, count: length)
}

private final class KeyboardEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [CGEvent] = []

    var events: [CGEvent] { lock.withLock { recordedEvents } }

    func append(_ event: CGEvent) {
        lock.withLock { recordedEvents.append(event) }
    }
}

@Test("Device revocation waits for earlier remote input and its reset to finish")
func remoteInputReleaseIsCompletionBarrier() {
    let inputQueue = DispatchQueue(label: "GlassyHostTests.pending-remote-input")
    let service = RemoteInputService(inputQueue: inputQueue)
    let earlierInputStarted = DispatchSemaphore(value: 0)
    let finishEarlierInput = DispatchSemaphore(value: 0)
    let releaseStarted = DispatchSemaphore(value: 0)
    let releaseCompleted = DispatchSemaphore(value: 0)

    inputQueue.async {
        earlierInputStarted.signal()
        finishEarlierInput.wait()
    }
    #expect(earlierInputStarted.wait(timeout: .now() + 2) == .success)
    DispatchQueue.global().async {
        releaseStarted.signal()
        service.releasePressedInput()
        releaseCompleted.signal()
    }
    #expect(releaseStarted.wait(timeout: .now() + 2) == .success)

    // An asynchronous reset would incorrectly report completion while this
    // earlier input is still blocked on its queue.
    let returnedBeforeInputFinished = releaseCompleted.wait(timeout: .now() + 0.05)
    finishEarlierInput.signal()
    #expect(returnedBeforeInputFinished == .timedOut)
    if returnedBeforeInputFinished == .timedOut {
        #expect(releaseCompleted.wait(timeout: .now() + 2) == .success)
    }
}
