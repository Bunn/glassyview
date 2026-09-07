import Foundation
import Testing
@testable import GlassyDesk

@MainActor
struct GlassyStreamCredentialLifecycleTests {
    @Test
    func forgettingPairingRemovesAuthorizationBeforeSaving() {
        let fixture = CredentialLifecycleFixture()
        var unpaired = fixture.machine
        unpaired.glassyHostIdentifier = nil
        unpaired.glassyHostName = nil
        #expect(fixture.store.update(unpaired, password: ""))
        #expect(fixture.remover.removals == [fixture.machine.id])
        #expect(fixture.store.machine(withID: fixture.machine.id)?.glassyHostIdentifier == nil)
    }

    @Test
    func ordinaryEditsAndNewAuthenticatedBindingPreserveCredentials() {
        let fixture = CredentialLifecycleFixture()
        var renamed = fixture.machine
        renamed.name = "Renamed"
        #expect(fixture.store.update(renamed, password: ""))
        #expect(fixture.remover.removals.isEmpty)

        var newMachine = SavedMachine(name: "New", host: "new.local", username: "",
                                     connectionMode: .glassyStream)
        fixture.store.add(newMachine, password: "")
        newMachine.glassyHostIdentifier = Data(repeating: 8, count: 16).base64EncodedString()
        #expect(fixture.store.update(newMachine, password: ""))
        #expect(fixture.remover.removals.isEmpty)
    }

    @Test
    func failedCredentialDeletionRetainsOriginalBindingAndMachine() {
        let fixture = CredentialLifecycleFixture(fails: true)
        var unpaired = fixture.machine
        unpaired.glassyHostIdentifier = nil
        #expect(!fixture.store.update(unpaired, password: ""))
        #expect(fixture.store.machine(withID: fixture.machine.id)?.glassyHostIdentifier
                == fixture.machine.glassyHostIdentifier)
        #expect(!fixture.store.delete(fixture.machine))
        #expect(fixture.store.contains(fixture.machine))
    }

    @Test
    func deletingMachineCleansLocalResumeBindings() {
        let fixture = CredentialLifecycleFixture()
        #expect(fixture.store.delete(fixture.machine))
        #expect(fixture.remover.removals == [fixture.machine.id])
        #expect(!fixture.store.contains(fixture.machine))
    }

    @Test
    func credentialAccountCleanupIsScopedToExactSavedMachine() {
        let id = UUID()
        let prefix = id.uuidString.lowercased()
        #expect(GlassyStreamKeychainCredentialStore.account("\(prefix):host1", belongsTo: id))
        #expect(GlassyStreamKeychainCredentialStore.account("\(prefix):host2", belongsTo: id))
        #expect(!GlassyStreamKeychainCredentialStore.account("\(UUID().uuidString.lowercased()):host1", belongsTo: id))
        #expect(!GlassyStreamKeychainCredentialStore.account("\(prefix)extra:host1", belongsTo: id))
    }

    @Test
    func keychainCleanupRemovesOnlyThisMachinesSyntheticCredentials() throws {
        // A unique test service ensures no production account or credential
        // is queried. Exercise the actual attributes-only Keychain deletion.
        let keychain = GlassyStreamKeychainCredentialStore(
            service: "dev.bunn.glassydesk.tests.resume.\(UUID().uuidString)"
        )
        let forgottenID = UUID()
        let preservedID = UUID()
        defer {
            try? keychain.removeCredentials(savedMachineID: forgottenID)
            try? keychain.removeCredentials(savedMachineID: preservedID)
        }
        let firstHost = Data(repeating: 1, count: 16)
        let formerHost = Data(repeating: 2, count: 16)
        let synthetic = GlassyStreamResumeCredential(
            clientIdentifier: Data(repeating: 3, count: 16),
            resumeSecret: Data(repeating: 4, count: 32)
        )
        try keychain.save(synthetic, savedMachineID: forgottenID, hostIdentifier: firstHost)
        try keychain.save(synthetic, savedMachineID: forgottenID, hostIdentifier: formerHost)
        try keychain.save(synthetic, savedMachineID: preservedID, hostIdentifier: firstHost)
        try keychain.removeCredentials(savedMachineID: forgottenID)
        #expect(try keychain.credential(savedMachineID: forgottenID, hostIdentifier: firstHost) == nil)
        #expect(try keychain.credential(savedMachineID: forgottenID, hostIdentifier: formerHost) == nil)
        #expect(try keychain.credential(savedMachineID: preservedID, hostIdentifier: firstHost) == synthetic)
        // Repeating deletion is safe when nothing remains.
        try keychain.removeCredentials(savedMachineID: forgottenID)
    }
}

@MainActor
private struct CredentialLifecycleFixture {
    let machine = SavedMachine(name: "Studio", host: "studio.local", username: "",
                               connectionMode: .glassyStream,
                               glassyHostIdentifier: Data(repeating: 7, count: 16).base64EncodedString())
    let remover: CredentialLifecycleRemover
    let store: MachineStore

    init(fails: Bool = false) {
        let remover = CredentialLifecycleRemover(fails: fails)
        self.remover = remover
        store = MachineStore(repository: CredentialLifecycleRepository(machine: machine),
                             resumeCredentialRemover: remover)
    }
}

private final class CredentialLifecycleRemover: GlassyStreamResumeCredentialRemoving, @unchecked Sendable {
    private let lock = NSLock()
    private let fails: Bool
    private var recordedRemovals: [UUID] = []
    init(fails: Bool) { self.fails = fails }
    var removals: [UUID] { lock.withLock { recordedRemovals } }
    func removeCredentials(savedMachineID: UUID) throws {
        try lock.withLock {
            if fails { throw CocoaError(.fileReadNoPermission) }
            recordedRemovals.append(savedMachineID)
        }
    }
}

private final class CredentialLifecycleRepository: SavedMachineRepository {
    private var machines: [SavedMachine]
    init(machine: SavedMachine) { machines = [machine] }
    func loadMachines() -> [SavedMachine] { machines }
    func addMachine(_ machine: SavedMachine) { machines.append(machine) }
    func updateMachine(_ machine: SavedMachine) {
        if let index = machines.firstIndex(where: { $0.id == machine.id }) { machines[index] = machine }
    }
    func deleteMachine(withID id: UUID) { machines.removeAll { $0.id == id } }
    func loadRecentConnections(limit: Int) -> [ConnectionHistoryEntry] { [] }
    func startSession(withID id: UUID, to machine: SavedMachine, connectedAt: Date) {}
    func finishSession(withID id: UUID, endedAt: Date, outcome: ConnectionHistoryOutcome) {}
    func deleteRecentConnection(withID id: UUID) {}
    func clearRecentConnections() {}
    func password(for id: UUID) -> String? { nil }
    func setPassword(_ password: String, for id: UUID) {}
    func deletePassword(for id: UUID) {}
    func sessionPreferences(for id: UUID) -> SessionPreferences { .default }
    func setSessionPreferences(_ preferences: SessionPreferences, for id: UUID) {}
}
