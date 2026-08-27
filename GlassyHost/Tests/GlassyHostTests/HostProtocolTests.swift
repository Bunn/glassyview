import CryptoKit
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

@Test("Pairing codes rotate by time window without exposing the root secret")
func pairingCodeRotation() {
    let rootSecret = SymmetricKey(data: Data(repeating: 0xA5, count: 32))
    let first = HostProtocol.pairingCode(rootSecret: rootSecret, window: 100)
    let same = HostProtocol.pairingCode(rootSecret: rootSecret, window: 100)
    let next = HostProtocol.pairingCode(rootSecret: rootSecret, window: 101)

    #expect(first == same)
    #expect(first != next)
    #expect(first.count == 14)
    #expect(first.split(separator: "-").allSatisfy { $0.count == 4 })
}
