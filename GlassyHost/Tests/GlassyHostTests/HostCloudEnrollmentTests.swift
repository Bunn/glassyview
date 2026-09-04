import CryptoKit
import Foundation
import Testing
@testable import GlassyHost

@Test("Cloud enrollment identifiers and authenticated context match the shared vectors")
func cloudEnrollmentSharedVectors() {
    let publicKey = Data((0..<32).map(UInt8.init))
    let hostIdentifier = Data((0..<16).map(UInt8.init))
    let requestNonce = Data((32..<64).map(UInt8.init))
    let clientIdentifier = HostCloudEnrollmentSchema.clientIdentifier(publicKey: publicKey)

    #expect(clientIdentifier.hex == "64c5b1f5ffcd1d1d21d6118a9e3c13b7")
    let context = HostCloudEnrollmentSchema.keyDerivationInfo(
        hostIdentifier: hostIdentifier,
        clientIdentifier: clientIdentifier,
        requestNonce: requestNonce,
        grantExpiresAtMilliseconds: 1_788_472_512_345
    )
    #expect(Data(SHA256.hash(data: context)).hex ==
        "8b8dfd5ecdea0eb2e83607b2716337148cb4d096e96eb7822fe5d1a68c5f96f4")
}

@Test("Cloud enrollment envelopes open only for the requesting device and exact context")
func cloudEnrollmentEnvelopeBinding() throws {
    let hostIdentifier = Data(repeating: 0x11, count: HostProtocol.identifierLength)
    let requestNonce = Data(repeating: 0x22, count: HostCloudEnrollmentSchema.requestNonceLength)
    let grant = Data(repeating: 0x33, count: HostProtocol.enrollmentGrantLength)
    let clientPrivateKey = try Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: Data((1...32).map(UInt8.init))
    )
    let clientIdentifier = HostCloudEnrollmentSchema.clientIdentifier(
        publicKey: clientPrivateKey.publicKey.rawRepresentation
    )
    let hostPrivateKey = try Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: Data((1...32).reversed().map(UInt8.init))
    )
    let expiry: UInt64 = 1_788_472_512_345

    let envelope = try HostCloudEnrollmentEnvelope.seal(
        grant: grant,
        hostIdentifier: hostIdentifier,
        clientIdentifier: clientIdentifier,
        clientPublicKey: clientPrivateKey.publicKey.rawRepresentation,
        requestNonce: requestNonce,
        grantExpiresAtMilliseconds: expiry,
        privateKey: hostPrivateKey
    )
    let hostPublicKey = try Curve25519.KeyAgreement.PublicKey(
        rawRepresentation: envelope.hostEphemeralPublicKey
    )
    let sharedSecret = try clientPrivateKey.sharedSecretFromKeyAgreement(with: hostPublicKey)
    let context = HostCloudEnrollmentSchema.keyDerivationInfo(
        hostIdentifier: hostIdentifier,
        clientIdentifier: clientIdentifier,
        requestNonce: requestNonce,
        grantExpiresAtMilliseconds: expiry
    )
    let key = sharedSecret.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: requestNonce,
        sharedInfo: context,
        outputByteCount: 32
    )
    let box = try AES.GCM.SealedBox(combined: envelope.sealedGrant)
    #expect(try AES.GCM.open(box, using: key, authenticating: context) == grant)
    #expect(throws: (any Error).self) {
        var wrongContext = context
        wrongContext[wrongContext.startIndex] ^= 1
        _ = try AES.GCM.open(box, using: key, authenticating: wrongContext)
    }
}

@Test("A cloud enrollment grant is bound, expiring, idempotent, and one-time")
func cloudEnrollmentGrantLifecycle() throws {
    let store = HostEnrollmentGrantStore()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let identifier = Data(repeating: 0x44, count: HostProtocol.identifierLength)
    let firstNonce = Data(repeating: 0x55, count: HostCloudEnrollmentSchema.requestNonceLength)
    let expiry = now.addingTimeInterval(60)
    let first = try store.issue(
        clientIdentifier: identifier,
        requestNonce: firstNonce,
        expiresAt: expiry,
        now: now
    )
    #expect(try store.issue(
        clientIdentifier: identifier,
        requestNonce: firstNonce,
        expiresAt: expiry,
        now: now
    ) == first)
    let refreshedExpiry = expiry.addingTimeInterval(30)
    #expect(try store.issue(
        clientIdentifier: identifier,
        requestNonce: firstNonce,
        expiresAt: refreshedExpiry,
        now: now.addingTimeInterval(1)
    ) == first)
    #expect(try store.credential(
        clientIdentifier: identifier,
        now: expiry.addingTimeInterval(1)
    ) == first)
    #expect(try store.credential(clientIdentifier: identifier, now: now) == first)
    #expect(store.consume(clientIdentifier: identifier, credential: first, now: now))
    #expect(!store.consume(clientIdentifier: identifier, credential: first, now: now))

    let second = try store.issue(
        clientIdentifier: identifier,
        requestNonce: Data(repeating: 0x66, count: HostCloudEnrollmentSchema.requestNonceLength),
        expiresAt: refreshedExpiry,
        now: now
    )
    #expect(second != first)
    store.remove(clientIdentifier: identifier, requestNonce: firstNonce)
    #expect(try store.credential(clientIdentifier: identifier, now: now) == second)
    #expect(throws: HostProtocol.ProtocolError.self) {
        try store.credential(clientIdentifier: identifier, now: refreshedExpiry)
    }
}

@Test("Private iCloud enrollment never overrides an explicit device revocation")
func cloudEnrollmentRespectsRevocation() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = HostDeviceAccessStore(fileURL: directory.appendingPathComponent("access.json"))
    let identifier = Data(repeating: 0x77, count: HostProtocol.identifierLength)

    #expect(store.permitsCloudEnrollment(identifier: identifier))
    try store.recordCloudEnrollmentAuthentication(identifier: identifier, name: "New iPhone")
    try store.revoke(identifier: identifier)
    #expect(!store.permitsCloudEnrollment(identifier: identifier))
    #expect(throws: HostProtocol.ProtocolError.self) {
        try store.recordCloudEnrollmentAuthentication(identifier: identifier, name: "New iPhone")
    }
}

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
