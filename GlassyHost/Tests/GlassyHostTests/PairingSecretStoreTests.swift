import Foundation
import Security
import Testing
@testable import GlassyHost

@Test("Unavailable production Keychain never substitutes a different pairing identity",
      arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled])
func pairingSecretKeychainFailurePreservesIdentity(status: OSStatus) throws {
    let keychain = PairingSecretKeychainFixture(data: Data(repeating: 0x42, count: 32))
    let store = PairingSecretStore(storageMode: .keychain, keychain: keychain)
    let original = try store.loadOrCreate()
    keychain.setFailure(status)
    #expect(throws: PairingSecretStoreError.self) { try store.loadOrCreate() }
    #expect(keychain.writeAttempts == 0)
    keychain.setFailure(nil)
    #expect(try store.loadOrCreate() == original)
}

@Test("Failed production pairing reset leaves the existing Keychain root recoverable",
      arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled])
func pairingSecretFailedResetPreservesIdentity(status: OSStatus) throws {
    let keychain = PairingSecretKeychainFixture(data: Data(repeating: 0x42, count: 32))
    let store = PairingSecretStore(storageMode: .keychain, keychain: keychain)
    let original = try store.loadOrCreate()
    keychain.setFailure(status)
    #expect(throws: PairingSecretStoreError.self) { try store.replace() }
    keychain.setFailure(nil)
    #expect(try store.loadOrCreate() == original)
}

@Test("Corrupt Keychain roots are not treated as a first launch", arguments: [0, 16, 31, 33])
func pairingSecretMalformedRootDoesNotReplace(length: Int) {
    let keychain = PairingSecretKeychainFixture(data: Data(repeating: 7, count: length))
    let store = PairingSecretStore(storageMode: .keychain, keychain: keychain)
    #expect(throws: PairingSecretStoreError.self) { try store.loadOrCreate() }
    #expect(keychain.writeAttempts == 0)
}

@Test("Missing production pairing key is created once and reused")
func pairingSecretFirstLaunchAndExplicitRotation() throws {
    let keychain = PairingSecretKeychainFixture(data: nil)
    let store = PairingSecretStore(storageMode: .keychain, keychain: keychain)
    let created = try store.loadOrCreate()
    #expect(created.keyData.count == 32)
    #expect(try store.loadOrCreate() == created)
    #expect(keychain.writeAttempts == 1)
    let replacement = try store.replace()
    #expect(replacement != created)
    #expect(try store.loadOrCreate() == replacement)
    #expect(keychain.writeAttempts == 2)
}

private final class PairingSecretKeychainFixture: PairingSecretKeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var failure: OSStatus?
    private var writes = 0

    init(data: Data?) { self.data = data }
    var writeAttempts: Int { lock.withLock { writes } }
    func setFailure(_ status: OSStatus?) { lock.withLock { failure = status } }

    func load() throws -> Data? {
        try lock.withLock {
            if let failure { throw PairingSecretStoreError.keychain(failure) }
            return data
        }
    }

    func save(_ data: Data) throws {
        try lock.withLock {
            writes += 1
            if let failure { throw PairingSecretStoreError.keychain(failure) }
            self.data = data
        }
    }
}
