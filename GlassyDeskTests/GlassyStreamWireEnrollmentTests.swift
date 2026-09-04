import CryptoKit
import Foundation
import Testing
@testable import GlassyDesk

struct GlassyStreamWireEnrollmentTests {
    @Test("Cloud enrollment keeps its capability and authentication wire values stable")
    func cloudEnrollmentWireValues() {
        #expect(GlassyStreamWire.Capabilities.cloudEnrollment.rawValue == 0x0000_0040)
        #expect(GlassyStreamWire.AuthenticationMethod.enrollmentGrantV1.rawValue == 4)
        #expect(GlassyStreamWire.enrollmentGrantLength == 32)
    }

    @Test("An enrollment proof is bound to the requesting device identifier")
    func enrollmentProofBindsUniqueClientIdentifier() throws {
        let serverKey = Curve25519.KeyAgreement.PrivateKey()
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let sharedSecret = try clientKey.sharedSecretFromKeyAgreement(with: serverKey.publicKey)
        let grant = Data(repeating: 0xA7, count: GlassyStreamWire.enrollmentGrantLength)
        let serverHello = GlassyStreamWire.ServerHello(
            hostIdentifier: Data(repeating: 0x11, count: GlassyStreamWire.identifierLength),
            serverNonce: Data(repeating: 0x22, count: GlassyStreamWire.nonceLength),
            serverPublicKey: serverKey.publicKey.rawRepresentation,
            pairingWindow: 1_234,
            pairingCodeLifetimeSeconds: 60,
            capabilities: GlassyStreamWire.Capabilities.cloudEnrollment.rawValue,
            serverName: "Fixture Mac"
        )

        let first = hello(
            identifier: Data(repeating: 0x31, count: GlassyStreamWire.identifierLength),
            publicKey: clientKey.publicKey.rawRepresentation
        )
        let second = hello(
            identifier: Data(repeating: 0x32, count: GlassyStreamWire.identifierLength),
            publicKey: clientKey.publicKey.rawRepresentation
        )
        let firstTranscript = try GlassyStreamWire.authenticationTranscript(
            serverHello: serverHello,
            clientHello: first
        )
        let secondTranscript = try GlassyStreamWire.authenticationTranscript(
            serverHello: serverHello,
            clientHello: second
        )
        let firstProof = GlassyStreamWire.authenticationProof(
            authenticationKey: GlassyStreamWire.authenticationKey(
                sharedSecret: sharedSecret,
                credential: grant,
                transcript: firstTranscript
            ),
            transcript: firstTranscript
        )
        let secondProof = GlassyStreamWire.authenticationProof(
            authenticationKey: GlassyStreamWire.authenticationKey(
                sharedSecret: sharedSecret,
                credential: grant,
                transcript: secondTranscript
            ),
            transcript: secondTranscript
        )

        #expect(firstTranscript != secondTranscript)
        #expect(firstProof != secondProof)
        #expect(firstProof.count == GlassyStreamWire.proofLength)
        #expect(secondProof.count == GlassyStreamWire.proofLength)
    }

    private func hello(identifier: Data, publicKey: Data) -> GlassyStreamWire.ClientHello {
        GlassyStreamWire.ClientHello(
            clientIdentifier: identifier,
            clientNonce: Data(repeating: 0x44, count: GlassyStreamWire.nonceLength),
            clientPublicKey: publicKey,
            authenticationMethod: .enrollmentGrantV1,
            pairingWindow: 0,
            clientName: "Fixture Device",
            proof: Data(repeating: 0, count: GlassyStreamWire.proofLength)
        )
    }
}
