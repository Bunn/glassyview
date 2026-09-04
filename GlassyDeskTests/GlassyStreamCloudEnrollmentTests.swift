import CryptoKit
import Foundation
import Testing
@testable import GlassyDesk

@Suite("Glassy Stream iCloud enrollment")
struct GlassyStreamCloudEnrollmentTests {
    @Test("Device identifier and enrollment context match the host vectors")
    func crossPlatformVectors() throws {
        let publicKey = Data(0x00...0x1f)
        let hostIdentifier = Data(0x00...0x0f)
        let requestNonce = Data(0x20...0x3f)
        let clientIdentifier = try GlassyStreamDeviceIdentityDerivation.clientIdentifier(
            publicKey: publicKey
        )

        #expect(clientIdentifier.hexString == "64c5b1f5ffcd1d1d21d6118a9e3c13b7")

        let grantExpiresAt = Date(timeIntervalSince1970: 1_788_472_512.345)
        let context = try GlassyStreamCloudEnrollmentCrypto.context(
            version: 1,
            hostIdentifier: hostIdentifier,
            clientIdentifier: clientIdentifier,
            requestNonce: requestNonce,
            grantExpiresAt: grantExpiresAt
        )
        #expect(context.hexString == "476c6173737920486f737420636c6f756420656e726f6c6c6d656e74207631000000000000000001000102030405060708090a0b0c0d0e0f64c5b1f5ffcd1d1d21d6118a9e3c13b7202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f000001a06944cf59")
        #expect(Data(SHA256.hash(data: context)).hexString == "8b8dfd5ecdea0eb2e83607b2716337148cb4d096e96eb7822fe5d1a68c5f96f4")
    }

    @Test("Only the requesting device can decrypt a bound enrollment grant")
    func decryptsDeviceBoundGrant() throws {
        let identity = GlassyStreamDeviceIdentity(
            privateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        )
        let hostKey = Curve25519.KeyAgreement.PrivateKey()
        let hostIdentifier = Data(repeating: 0x41, count: GlassyStreamWire.identifierLength)
        let clientIdentifier = try identity.clientIdentifier
        let requestNonce = Data(repeating: 0x52, count: GlassyStreamWire.nonceLength)
        let grantExpiresAt = Date.now.addingTimeInterval(120)
        let context = try GlassyStreamCloudEnrollmentCrypto.context(
            version: 1,
            hostIdentifier: hostIdentifier,
            clientIdentifier: clientIdentifier,
            requestNonce: requestNonce,
            grantExpiresAt: grantExpiresAt
        )
        let clientPublicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: identity.publicKey
        )
        let sharedSecret = try hostKey.sharedSecretFromKeyAgreement(with: clientPublicKey)
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: requestNonce,
            sharedInfo: context,
            outputByteCount: 32
        )
        let expectedGrant = Data(repeating: 0x63, count: GlassyStreamWire.enrollmentGrantLength)
        let sealedGrant = try #require(
            AES.GCM.seal(expectedGrant, using: key, authenticating: context).combined
        )

        let openedGrant = try GlassyStreamCloudEnrollmentCrypto.openGrant(
            sealedGrant: sealedGrant,
            hostEphemeralPublicKey: hostKey.publicKey.rawRepresentation,
            identity: identity,
            hostIdentifier: hostIdentifier,
            clientIdentifier: clientIdentifier,
            requestNonce: requestNonce,
            grantExpiresAt: grantExpiresAt,
            now: grantExpiresAt.addingTimeInterval(-60)
        )
        #expect(openedGrant == expectedGrant)

        let otherIdentity = GlassyStreamDeviceIdentity(
            privateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        )
        #expect(throws: GlassyStreamCloudEnrollmentError.self) {
            _ = try GlassyStreamCloudEnrollmentCrypto.openGrant(
                sealedGrant: sealedGrant,
                hostEphemeralPublicKey: hostKey.publicKey.rawRepresentation,
                identity: otherIdentity,
                hostIdentifier: hostIdentifier,
                clientIdentifier: clientIdentifier,
                requestNonce: requestNonce,
                grantExpiresAt: grantExpiresAt,
                now: grantExpiresAt.addingTimeInterval(-60)
            )
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
