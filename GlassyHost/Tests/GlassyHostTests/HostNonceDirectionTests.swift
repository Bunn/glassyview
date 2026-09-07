import CryptoKit
import Foundation
import Testing
@testable import GlassyHost

@Test("Overlapping direction nonce domains are rejected before any encryption",
      arguments: [false, true])
func hostRejectsNonceDirectionCollision(serverToClient: Bool) throws {
    let prefix = Data([1, 2, 3, 4])
    let material = HostProtocol.SessionMaterial(
        encryptionKey: SymmetricKey(data: Data(repeating: 0x42, count: 32)),
        serverToClientNoncePrefix: prefix, clientToServerNoncePrefix: prefix
    )
    #expect(throws: HostProtocol.ProtocolError.self) {
        try HostProtocol.seal(Data("input".utf8), kind: .ping, flags: [], sequence: 2,
                              material: material, serverToClient: serverToClient)
    }
    // Construct otherwise-valid ciphertext independently to ensure open
    // rejects the nonce domain itself, rather than merely a malformed tag.
    let flags: HostProtocol.Flags = [.encrypted]
    let nonce = try AES.GCM.Nonce(data: prefix + Data([0, 0, 0, 0, 0, 0, 0, 2]))
    let box = try AES.GCM.seal(Data("input".utf8), using: material.encryptionKey,
                               nonce: nonce, authenticating: HostProtocol.authenticatedAdditionalData(
                                kind: .ping, flags: flags, sequence: 2))
    #expect(throws: HostProtocol.ProtocolError.self) {
        try HostProtocol.open(box.ciphertext + box.tag, kind: .ping, flags: flags,
                              sequence: 2, material: material, serverToClient: serverToClient)
    }
}
