import CryptoKit
import Foundation
import Testing
@testable import GlassyDesk

struct GlassyStreamNonceDirectionTests {
    @Test(arguments: [false, true])
    func rejectsOverlappingNonceDomains(serverToClient: Bool) throws {
        let prefix = Data([1, 2, 3, 4])
        let material = GlassyStreamWire.SessionMaterial(
            encryptionKey: SymmetricKey(data: Data(repeating: 0x42, count: 32)),
            serverToClientNoncePrefix: prefix, clientToServerNoncePrefix: prefix
        )
        #expect(throws: GlassyStreamClientError.self) {
            try GlassyStreamWire.seal(Data("input".utf8), kind: .ping, flags: [], sequence: 2,
                                     material: material, serverToClient: serverToClient)
        }
        // GLSY / v1 / ping / encrypted / sequence 2: valid authenticated
        // ciphertext isolates the direction-collision guard from tag failure.
        let aad = Data([0x47, 0x4c, 0x53, 0x59, 1, 5, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2])
        let nonce = try AES.GCM.Nonce(data: prefix + Data([0, 0, 0, 0, 0, 0, 0, 2]))
        let box = try AES.GCM.seal(Data("input".utf8), using: material.encryptionKey,
                                  nonce: nonce, authenticating: aad)
        #expect(throws: GlassyStreamClientError.self) {
            try GlassyStreamWire.open(box.ciphertext + box.tag, kind: .ping, flags: [.encrypted],
                                     sequence: 2, material: material, serverToClient: serverToClient)
        }
    }
}
