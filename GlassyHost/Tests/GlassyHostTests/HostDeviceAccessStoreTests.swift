import CryptoKit
import Foundation
import Testing
@testable import GlassyHost

@Test("Existing viewers retain their resume credentials when the device list is introduced")
func deviceAccessLegacyResumeMigration() throws {
    let fixture = DeviceAccessFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    let original = try HostProtocol.resumeSecret(rootSecret: fixture.key, clientIdentifier: fixture.firstID)
    #expect(try store.resumeSecret(rootSecret: fixture.key, identifier: fixture.firstID) == original)

    try store.recordAuthentication(identifier: fixture.firstID, name: "My iPad", isBootstrapPairing: false)
    let reloaded = fixture.store()
    #expect(try reloaded.resumeSecret(rootSecret: fixture.key, identifier: fixture.firstID) == original)
    #expect(reloaded.pairedDevices().map(\.name) == ["My iPad"])
    #expect(reloaded.pairedDevices().first?.isConnected == false)
}

@Test("Revocation survives a host relaunch and rejects resume authentication")
func deviceAccessRevocationPersists() throws {
    let fixture = DeviceAccessFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    try store.recordAuthentication(identifier: fixture.firstID, name: "iPhone", isBootstrapPairing: true)
    try store.revoke(identifier: fixture.firstID)

    let reloaded = fixture.store()
    #expect(reloaded.pairedDevices().isEmpty)
    #expect(throws: HostProtocol.ProtocolError.self) {
        try reloaded.resumeSecret(rootSecret: fixture.key, identifier: fixture.firstID)
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        try reloaded.recordAuthentication(identifier: fixture.firstID, name: "iPhone", isBootstrapPairing: false)
    }
}

@Test("Fresh pairing restores a revoked identity without restoring its old credential")
func deviceAccessFreshPairingRotatesCredential() throws {
    let fixture = DeviceAccessFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    try store.recordAuthentication(identifier: fixture.firstID, name: "iPhone", isBootstrapPairing: true)
    let original = try store.resumeSecret(rootSecret: fixture.key, identifier: fixture.firstID)
    try store.revoke(identifier: fixture.firstID)

    let reloaded = fixture.store()
    try reloaded.recordAuthentication(identifier: fixture.firstID, name: "Renamed iPhone", isBootstrapPairing: true)
    let renewed = try reloaded.resumeSecret(rootSecret: fixture.key, identifier: fixture.firstID)
    #expect(renewed != original)
    #expect(renewed.count == HostProtocol.resumeSecretLength)
    #expect(try fixture.store().resumeSecret(rootSecret: fixture.key, identifier: fixture.firstID) == renewed)
    #expect(reloaded.pairedDevices().map(\.name) == ["Renamed iPhone"])
}

@Test("Revoking one device preserves another device's resume credential")
func deviceAccessRevocationIsScoped() throws {
    let fixture = DeviceAccessFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    for identifier in [fixture.firstID, fixture.secondID] {
        try store.recordAuthentication(identifier: identifier, name: "Device", isBootstrapPairing: true)
    }
    let otherCredential = try store.resumeSecret(rootSecret: fixture.key, identifier: fixture.secondID)
    try store.revoke(identifier: fixture.firstID)
    #expect(try store.resumeSecret(rootSecret: fixture.key, identifier: fixture.secondID) == otherCredential)
    let devices = store.pairedDevices(connectedIdentifiers: [fixture.secondID])
    #expect(devices.count == 1)
    #expect(devices.first?.id == fixture.secondID)
    #expect(devices.first?.isConnected == true)
}

@Test("The connection switch persists and blocks both resumed and fresh pairing")
func deviceAccessDisabledPersists() throws {
    let fixture = DeviceAccessFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    try store.setAllowsConnections(false)
    let reloaded = fixture.store()
    #expect(!reloaded.allowsConnections)
    #expect(throws: HostProtocol.ProtocolError.self) {
        try reloaded.resumeSecret(rootSecret: fixture.key, identifier: fixture.firstID)
    }
    #expect(throws: HostProtocol.ProtocolError.self) {
        try reloaded.recordAuthentication(identifier: fixture.firstID, name: "iPad", isBootstrapPairing: true)
    }
    try reloaded.setAllowsConnections(true)
    #expect(fixture.store().allowsConnections)
}

@Test("Unreadable permissions fail closed and require fresh pairing after re-enabling")
func deviceAccessCorruptionFailsClosed() throws {
    let fixture = DeviceAccessFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    try Data("damaged permissions".utf8).write(to: fixture.fileURL)
    let store = fixture.store()
    #expect(!store.allowsConnections)
    try store.setAllowsConnections(true)
    #expect(throws: HostProtocol.ProtocolError.self) {
        try store.resumeSecret(rootSecret: fixture.key, identifier: fixture.firstID)
    }
    try store.recordAuthentication(identifier: fixture.firstID, name: "iPad", isBootstrapPairing: true)
    let renewed = try store.resumeSecret(rootSecret: fixture.key, identifier: fixture.firstID)
    let legacy = try HostProtocol.resumeSecret(rootSecret: fixture.key, clientIdentifier: fixture.firstID)
    #expect(renewed != legacy)
    #expect(try fixture.store().resumeSecret(rootSecret: fixture.key, identifier: fixture.firstID) == renewed)
}

@Test("Failed permission writes do not claim a device has been revoked")
func deviceAccessWriteFailureDoesNotCommit() throws {
    let fixture = DeviceAccessFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    try store.recordAuthentication(identifier: fixture.firstID, name: "iPad", isBootstrapPairing: true)
    try FileManager.default.removeItem(at: fixture.fileURL)
    try FileManager.default.removeItem(at: fixture.directory)
    try Data("not a directory".utf8).write(to: fixture.directory)
    #expect(throws: (any Error).self) { try store.revoke(identifier: fixture.firstID) }
    #expect(store.pairedDevices().count == 1)
}

private struct DeviceAccessFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
    let firstID = Data(repeating: 0x01, count: HostProtocol.identifierLength)
    let secondID = Data(repeating: 0x02, count: HostProtocol.identifierLength)
    var fileURL: URL { directory.appendingPathComponent("access.json") }
    func store() -> HostDeviceAccessStore { HostDeviceAccessStore(fileURL: fileURL) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
