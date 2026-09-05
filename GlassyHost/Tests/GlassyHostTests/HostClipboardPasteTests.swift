import AppKit
import CryptoKit
import Foundation
import Testing
@testable import GlassyHost

@Test("Clipboard payloads preserve multiline Unicode, whitespace, and text above the typing limit")
func clipboardPayloadValidation() throws {
    let text = "  Café 👩🏽‍💻 日本語\r\n\t" + String(repeating: "a", count: 5_000) + "\n"
    #expect(try HostProtocol.decodeRemoteInput(kind: .clipboardPaste, payload: Data(text.utf8)) == .clipboardPaste(text))
    #expect(try HostProtocol.decodeClipboardPaste(Data(repeating: 0x61, count: 1_048_576)).utf8.count == 1_048_576)

    for invalid in [Data(), Data([0xC3, 0x28]), Data(repeating: 0x61, count: 1_048_577)] {
        #expect(throws: HostProtocol.ProtocolError.self) {
            try HostProtocol.decodeClipboardPaste(invalid)
        }
    }
}

@Test("A clipboard paste is authenticated and cannot be substituted for a typing event")
func clipboardPasteAuthentication() throws {
    let shared = try Curve25519.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(
        with: Curve25519.KeyAgreement.PrivateKey().publicKey
    )
    let material = HostProtocol.sessionMaterial(sharedSecret: shared,
                                               credential: Data(repeating: 7, count: 32),
                                               transcript: Data("clipboard test".utf8))
    let text = "First line\nSecond line 🦋"
    let sealed = try HostProtocol.seal(Data(text.utf8), kind: .clipboardPaste,
                                      flags: [], sequence: 4, material: material, serverToClient: false)
    let opened = try HostProtocol.open(sealed, kind: .clipboardPaste, flags: [.encrypted],
                                      sequence: 4, material: material, serverToClient: false)
    #expect(try HostProtocol.decodeClipboardPaste(opened) == text)
    #expect(throws: HostProtocol.ProtocolError.self) {
        try HostProtocol.open(sealed, kind: .textInput, flags: [.encrypted],
                              sequence: 4, material: material, serverToClient: false)
    }
}

@Test("The Mac clipboard is written before either paste key event")
func clipboardWritePrecedesPaste() {
    let recorder = ClipboardEventRecorder()
    let text = " exact\r\n👋\t"
    let service = HostClipboardPasteService(
        writeText: { text in recorder.append(.write(text)); return true },
        postKey: { code, isDown, flags in recorder.append(.key(code, isDown, flags.rawValue)) }
    )
    service.paste(text)
    service.paste(text)
    let expected: [ClipboardEventRecorder.Event] = [
        .write(text), .key(9, true, CGEventFlags.maskCommand.rawValue),
        .key(9, false, CGEventFlags.maskCommand.rawValue)
    ]
    #expect(recorder.events == expected + expected)
}

@Test("Failed writes and invalid text never paste stale Mac clipboard content")
func failedClipboardWriteDoesNotPaste() {
    let recorder = ClipboardEventRecorder()
    let service = HostClipboardPasteService(
        writeText: { text in recorder.append(.write(text)); return false },
        postKey: { code, isDown, flags in recorder.append(.key(code, isDown, flags.rawValue)) }
    )
    service.paste("new text")
    service.paste("")
    service.paste(String(repeating: "é", count: 524_289))
    #expect(recorder.events == [.write("new text")])
}

@Test("Clipboard writes obey the host's remote-control and Accessibility gates")
func clipboardPasteRequiresRemoteControl() {
    let recorder = ClipboardEventRecorder()
    let paste = HostClipboardPasteService(
        writeText: { text in recorder.append(.write(text)); return true },
        postKey: { _, _, _ in }
    )
    let disabled = RemoteInputService(clipboardPaste: paste, accessibilityCheck: { true })
    disabled.handle(.clipboardPaste("disabled"))
    disabled.releasePressedInput()
    let untrusted = RemoteInputService(clipboardPaste: paste, accessibilityCheck: { false })
    untrusted.setEnabled(true)
    untrusted.handle(.clipboardPaste("untrusted"))
    untrusted.releasePressedInput()
    #expect(recorder.events.isEmpty)

    disabled.setEnabled(true)
    disabled.handle(.clipboardPaste("allowed"))
    disabled.releasePressedInput()
    #expect(recorder.events == [.write("allowed")])
}

private final class ClipboardEventRecorder: @unchecked Sendable {
    enum Event: Equatable {
        case write(String)
        case key(CGKeyCode, Bool, UInt64)
    }
    private let lock = NSLock()
    private var storage: [Event] = []
    var events: [Event] { lock.withLock { storage } }
    func append(_ event: Event) { lock.withLock { storage.append(event) } }
}
