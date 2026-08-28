import CryptoKit
import CoreGraphics
import Foundation
import Testing
@testable import GlassyHost

@Test("Wire frames survive fragmented TCP input")
func fragmentedFrameRoundTrip() throws {
    let expected = HostProtocol.Frame(
        kind: .videoAccessUnit,
        flags: [.encrypted, .keyFrame],
        sequence: 42,
        payload: Data([1, 2, 3, 4])
    )
    let encoded = try HostProtocol.encode(expected)
    var buffer = Data(encoded.prefix(HostProtocol.headerLength - 1))

    #expect(try HostProtocol.decodeNextFrame(from: &buffer) == nil)

    buffer.append(encoded.dropFirst(HostProtocol.headerLength - 1))
    let decodedFrame = try HostProtocol.decodeNextFrame(from: &buffer)
    let decoded = try #require(decodedFrame)
    #expect(decoded.kind == expected.kind)
    #expect(decoded.flags == expected.flags)
    #expect(decoded.sequence == expected.sequence)
    #expect(decoded.payload == expected.payload)
    #expect(buffer.isEmpty)
}

@Test("Encrypted payloads authenticate header fields")
func encryptedPayloadRoundTrip() throws {
    let sharedSecret = try Curve25519.KeyAgreement.PrivateKey()
        .sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PrivateKey().publicKey
        )
    let material = HostProtocol.sessionMaterial(
        sharedSecret: sharedSecret,
        credential: Data(repeating: 7, count: 32),
        transcript: Data("test transcript".utf8)
    )
    let plaintext = Data("encoded frame".utf8)
    let ciphertext = try HostProtocol.seal(
        plaintext,
        kind: .videoAccessUnit,
        flags: [.keyFrame],
        sequence: 3,
        material: material,
        serverToClient: true
    )

    let opened = try HostProtocol.open(
        ciphertext,
        kind: .videoAccessUnit,
        flags: [.encrypted, .keyFrame],
        sequence: 3,
        material: material,
        serverToClient: true
    )
    #expect(opened == plaintext)

    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.open(
            ciphertext,
            kind: .videoAccessUnit,
            flags: [.encrypted],
            sequence: 3,
            material: material,
            serverToClient: true
        )
    }
}

@Test("Direct input is authenticated in the client-to-host direction")
func encryptedDirectInputRoundTrip() throws {
    let sharedSecret = try Curve25519.KeyAgreement.PrivateKey()
        .sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PrivateKey().publicKey
        )
    let material = HostProtocol.sessionMaterial(
        sharedSecret: sharedSecret,
        credential: Data(repeating: 9, count: 32),
        transcript: Data("direct input transcript".utf8)
    )
    let expected = HostProtocol.PointerInput(
        normalizedX: 12_345,
        normalizedY: 54_321,
        buttonMask: .left
    )
    let plaintext = try HostProtocol.encodePointerInput(expected)
    let sealed = try HostProtocol.seal(
        plaintext,
        kind: .pointerInput,
        flags: [],
        sequence: 2,
        material: material,
        serverToClient: false
    )
    let opened = try HostProtocol.open(
        sealed,
        kind: .pointerInput,
        flags: [.encrypted],
        sequence: 2,
        material: material,
        serverToClient: false
    )
    #expect(try HostProtocol.decodePointerInput(opened) == expected)

    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.open(
            sealed,
            kind: .pointerInput,
            flags: [.encrypted],
            sequence: 2,
            material: material,
            serverToClient: true
        )
    }
}

@Test("Pairing codes rotate by time window without exposing the root secret")
func pairingCodeRotation() {
    let rootSecret = SymmetricKey(data: Data(repeating: 0xA5, count: 32))
    let first = HostProtocol.pairingCode(rootSecret: rootSecret, window: 100)
    let same = HostProtocol.pairingCode(rootSecret: rootSecret, window: 100)
    let next = HostProtocol.pairingCode(rootSecret: rootSecret, window: 101)

    #expect(first == same)
    #expect(first != next)
    #expect(first.count == HostProtocol.pairingCodeSymbolCount)
    #expect(!first.contains("-"))
    #expect(HostProtocol.pairingCodeDisplayValue(first).count == 14)
    #expect(
        HostProtocol.pairingCodeDisplayValue(first)
            .split(separator: "-")
            .allSatisfy { $0.count == 4 }
    )
}

@Test("Protocol v1 reserves input, recovery, and quality-control values")
func directInputWireValues() throws {
    #expect(HostProtocol.Capabilities.directInput.rawValue == 0x0000_0004)
    #expect(HostProtocol.Capabilities.streamQualityControl.rawValue == 0x0000_0008)
    #expect(HostProtocol.advertisedCapabilities.rawValue == 0x0000_000F)
    #expect(HostProtocol.MessageKind.keyFrameRequest.rawValue == 0x12)
    #expect(HostProtocol.MessageKind.streamQualityRequest.rawValue == 0x13)
    #expect(HostProtocol.MessageKind.pointerInput.rawValue == 0x20)
    #expect(HostProtocol.MessageKind.scrollInput.rawValue == 0x21)
    #expect(HostProtocol.MessageKind.keyInput.rawValue == 0x22)
    #expect(HostProtocol.MessageKind.textInput.rawValue == 0x23)

    try HostProtocol.decodeKeyFrameRequest(Data())
    #expect(throws: HostProtocol.ProtocolError.self) {
        try HostProtocol.decodeKeyFrameRequest(Data([0]))
    }
}

@Test("Stream quality request codec uses exact allowlisted values")
func streamQualityRequestCodec() throws {
    #expect(HostProtocol.StreamQuality.dataSaver.rawValue == 0)
    #expect(HostProtocol.StreamQuality.balanced.rawValue == 1)
    #expect(HostProtocol.StreamQuality.best.rawValue == 2)

    for quality in HostProtocol.StreamQuality.allCases {
        let encoded = HostProtocol.encodeStreamQualityRequest(quality)
        #expect(encoded == Data([quality.rawValue, 0, 0, 0]))
        #expect(try HostProtocol.decodeStreamQualityRequest(encoded) == quality)
    }

    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodeStreamQualityRequest(Data([3, 0, 0, 0]))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodeStreamQualityRequest(Data([0, 0, 1, 0]))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodeStreamQualityRequest(Data([0, 0, 0]))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodeStreamQualityRequest(Data([0, 0, 0, 0, 0]))
    }
}

@Test("Pointer input codec is exact and rejects unknown fields")
func pointerInputCodec() throws {
    let value = HostProtocol.PointerInput(
        normalizedX: .min,
        normalizedY: .max,
        buttonMask: [.left, .right]
    )
    let encoded = try HostProtocol.encodePointerInput(value)
    #expect(encoded == Data([0, 0, 0xFF, 0xFF, 0x03, 0]))
    #expect(try HostProtocol.decodePointerInput(encoded) == value)
    #expect(
        try HostProtocol.decodeRemoteInput(kind: .pointerInput, payload: encoded)
            == .pointer(value)
    )

    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodePointerInput(Data([0, 0, 0, 0, 0x04, 0]))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodePointerInput(Data([0, 0, 0, 0, 0, 1]))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodePointerInput(encoded + Data([0]))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.encodePointerInput(
            .init(normalizedX: 0,
                  normalizedY: 0,
                  buttonMask: .init(rawValue: 0x80))
        )
    }
}

@Test("Scroll input codec enforces direction, reserved byte, and step bounds")
func scrollInputCodec() throws {
    for direction in [
        HostProtocol.ScrollDirection.up,
        .down,
        .left,
        .right
    ] {
        for steps: UInt16 in [1, 64] {
            let value = HostProtocol.ScrollInput(direction: direction, steps: steps)
            #expect(
                try HostProtocol.decodeScrollInput(
                    HostProtocol.encodeScrollInput(value)
                ) == value
            )
        }
    }

    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.encodeScrollInput(.init(direction: .up, steps: 0))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.encodeScrollInput(.init(direction: .up, steps: 65))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodeScrollInput(Data([4, 0, 0, 1]))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodeScrollInput(Data([0, 1, 0, 1]))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodeScrollInput(Data([0, 0, 0, 0]))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodeScrollInput(Data([0, 0, 0, 65]))
    }
}

@Test("Key input codec uses strict boolean and zero reserved bytes")
func keyInputCodec() throws {
    let value = HostProtocol.KeyInput(keysym: 0x0000_FF52, isDown: true)
    let encoded = HostProtocol.encodeKeyInput(value)
    #expect(encoded == Data([0, 0, 0xFF, 0x52, 1, 0, 0, 0]))
    #expect(try HostProtocol.decodeKeyInput(encoded) == value)

    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodeKeyInput(Data([0, 0, 0, 0, 2, 0, 0, 0]))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodeKeyInput(Data([0, 0, 0, 0, 1, 0, 1, 0]))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodeKeyInput(encoded + Data([0]))
    }
}

@Test("Text input codec preserves Unicode and enforces its UTF-8 envelope")
func textInputCodec() throws {
    let value = HostProtocol.TextInput(
        modifierMask: [.command, .shift, .option, .control],
        text: "Hello, Glassy 👋"
    )
    let encoded = try HostProtocol.encodeTextInput(value)
    #expect(try HostProtocol.decodeTextInput(encoded) == value)

    let maximum = HostProtocol.TextInput(
        modifierMask: [],
        text: String(repeating: "a", count: 4_096)
    )
    #expect(try HostProtocol.decodeTextInput(
        HostProtocol.encodeTextInput(maximum)
    ) == maximum)

    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.encodeTextInput(.init(modifierMask: [], text: ""))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.encodeTextInput(
            .init(modifierMask: [], text: String(repeating: "a", count: 4_097))
        )
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.encodeTextInput(
            .init(modifierMask: .init(rawValue: 0x10), text: "a")
        )
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodeTextInput(Data([0x10, 0, 0, 1, 0x61]))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodeTextInput(Data([0, 1, 0, 1, 0x61]))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodeTextInput(Data([0, 0, 0, 0]))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodeTextInput(Data([0, 0, 0, 1, 0xFF]))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodeTextInput(encoded + Data([0]))
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        _ = try HostProtocol.decodeRemoteInput(kind: .ping, payload: Data())
    }
}

@Test("Normalized input spans the selected display bounds")
func normalizedInputCoordinates() {
    let bounds = CGRect(x: -1_920, y: 100, width: 1_920, height: 1_080)
    #expect(
        RemoteInputService.point(normalizedX: .min,
                                 normalizedY: .min,
                                 in: bounds)
            == CGPoint(x: -1_920, y: 100)
    )
    #expect(
        RemoteInputService.point(normalizedX: .max,
                                 normalizedY: .max,
                                 in: bounds)
            == CGPoint(x: -1, y: 1_179)
    )
}

@Test("X11 keysyms cover printable, navigation, function, and modifier keys")
func x11KeysymMappings() {
    #expect(RemoteInputService.mappedKeyCode(forX11Keysym: 0x61) == 0)
    #expect(RemoteInputService.mappedKeyCode(forX11Keysym: 0x41) == 0)
    #expect(
        RemoteInputService.requiredFlags(forX11Keysym: 0x41)?
            .contains(.maskShift) == true
    )
    #expect(RemoteInputService.mappedKeyCode(forX11Keysym: 0xFF51) == 123)
    #expect(RemoteInputService.mappedKeyCode(forX11Keysym: 0xFFBE) == 122)
    #expect(RemoteInputService.mappedKeyCode(forX11Keysym: 0xFFE9) == 58)
    #expect(RemoteInputService.mappedKeyCode(forX11Keysym: 0xDEAD_BEEF) == nil)
}
