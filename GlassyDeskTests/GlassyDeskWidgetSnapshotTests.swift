import Foundation
import Testing
@testable import GlassyDesk

struct GlassyDeskWidgetSnapshotTests {
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func builderSanitizesSortsAndDeduplicatesMachines() {
        let machines = [
            input(id: secondID, name: "  ", order: 2),
            input(id: firstID, name: "  Studio Mac\n", order: 1),
            input(id: firstID, name: "Duplicate", order: 3)
        ]

        let snapshot = GlassyDeskWidgetSnapshotBuilder().build(
            machines: machines,
            generatedAt: now
        )

        #expect(snapshot.machines.map(\.id) == [firstID, secondID])
        #expect(snapshot.machines.map(\.displayName) == ["Studio Mac", "Saved Computer"])
        #expect(snapshot.machines.allSatisfy { $0.displayName.count <= 80 })
    }

    @Test
    func metadataRefreshPreservesStatusAndDeletingMachineDropsIt() {
        let previous = GlassyDeskWidgetSnapshot(
            generatedAt: now.addingTimeInterval(-60),
            machines: [
                WidgetMachineSnapshot(
                    id: firstID,
                    displayName: "Old Name",
                    connectionKind: .vnc,
                    lastConnectedAt: nil,
                    reachability: .reachable,
                    reachabilityCheckedAt: now.addingTimeInterval(-30)
                ),
                WidgetMachineSnapshot(
                    id: secondID,
                    displayName: "Deleted",
                    connectionKind: .vnc,
                    lastConnectedAt: nil,
                    reachability: .unreachable,
                    reachabilityCheckedAt: now.addingTimeInterval(-30)
                )
            ]
        )

        let snapshot = GlassyDeskWidgetSnapshotBuilder().build(
            machines: [input(id: firstID, name: "New Name", order: 0)],
            previous: previous,
            generatedAt: now
        )

        #expect(snapshot.machines.count == 1)
        #expect(snapshot.machines[0].displayName == "New Name")
        #expect(snapshot.machines[0].reachability == .reachable)
        #expect(snapshot.machines[0].reachabilityCheckedAt == now.addingTimeInterval(-30))
    }

    @Test
    func currentReachabilityGetsNewCheckTimestamp() {
        let snapshot = GlassyDeskWidgetSnapshotBuilder().build(
            machines: [input(id: firstID, name: "Mac", order: 0, reachability: .unreachable)],
            generatedAt: now,
            reachabilityCheckedAt: now
        )

        #expect(snapshot.machines[0].reachability == .unreachable)
        #expect(snapshot.machines[0].reachabilityCheckedAt == now)
    }

    @Test
    func fileStoreRoundTripsAndTreatsCorruptDataAsMissing() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directoryURL: directory)
        let expected = GlassyDeskWidgetSnapshotBuilder().build(
            machines: [input(id: firstID, name: "Mac", order: 0)],
            generatedAt: now
        )

        try store.write(expected)
        #expect(store.read() == expected)

        let fileURL = directory.appendingPathComponent(WidgetSnapshotStore.fileName)
        try Data("not-json".utf8).write(to: fileURL, options: .atomic)
        #expect(store.read() == nil)
    }

    @Test
    func fileStoreTellsMissingApartFromUnreadable() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directoryURL: directory)
        #expect(store.load() == .missing)

        let snapshot = GlassyDeskWidgetSnapshotBuilder().build(
            machines: [input(id: firstID, name: "Mac", order: 0)],
            generatedAt: now
        )
        try store.write(snapshot)
        #expect(store.load() == .snapshot(snapshot))

        // A file that exists but can't be opened, as when data protection keeps it locked.
        let fileURL = directory.appendingPathComponent(WidgetSnapshotStore.fileName)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }
        #expect(store.load() == .unreadable)
        #expect(store.read() == nil)
        #expect(WidgetSnapshotStore(directoryURL: nil).load() == .unreadable)
    }

    @Test @MainActor
    func failedMachineLoadDoesNotPublishAnEmptyList() {
        let repository = FlakySavedMachineRepository()
        let publisher = SpyWidgetSnapshotPublisher()
        repository.fails = true

        let machineStore = MachineStore(repository: repository, widgetSnapshotPublisher: publisher)
        #expect(!machineStore.hasLoadedMachines)
        #expect(publisher.publishedMachineCounts.isEmpty)

        repository.fails = false
        machineStore.reload()
        #expect(machineStore.hasLoadedMachines)
        #expect(publisher.publishedMachineCounts == [1])

        repository.fails = true
        machineStore.reload()
        #expect(machineStore.machines.count == 1)
        #expect(publisher.publishedMachineCounts == [1])
    }

    @Test
    func fileStoreRejectsUnknownSchemaVersions() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(WidgetSnapshotStore.fileName)
        let data = Data(#"{"schemaVersion":999,"generatedAt":0,"machines":[]}"#.utf8)
        try data.write(to: fileURL, options: .atomic)

        #expect(WidgetSnapshotStore(directoryURL: directory).read() == nil)
    }

    @Test
    func fileStoreRejectsOversizedSnapshotWithoutReplacingExistingData() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directoryURL: directory)
        let original = GlassyDeskWidgetSnapshotBuilder().build(
            machines: [input(id: firstID, name: "Mac", order: 0)],
            generatedAt: now
        )
        try store.write(original)

        let oversized = GlassyDeskWidgetSnapshot(
            generatedAt: now,
            machines: [
                WidgetMachineSnapshot(
                    id: secondID,
                    displayName: String(repeating: "x", count: WidgetSnapshotStore.maximumFileSize),
                    connectionKind: .vnc,
                    lastConnectedAt: nil,
                    reachability: .unknown,
                    reachabilityCheckedAt: nil
                )
            ]
        )

        #expect(throws: WidgetSnapshotStoreError.snapshotTooLarge) {
            try store.write(oversized)
        }
        #expect(store.read() == original)
    }

    @Test @MainActor
    func publishedRepresentationExcludesConnectionAndCredentialMetadata() throws {
        let host = "private-host-7f3a.example"
        let username = "private-user-7f3a"
        let macAddress = "AA:BB:CC:DD:EE:FF"
        let pairingID = "private-pairing-id-7f3a"
        let machine = SavedMachine(
            id: firstID,
            name: "",
            host: host,
            port: 59_001,
            username: username,
            connectionMode: .glassyStream,
            glassyHostIdentifier: pairingID,
            glassyHostName: "private-glassy-name-7f3a",
            glassyHostAddresses: ["10.20.30.40"],
            macAddress: macAddress
        )

        let data = WidgetSnapshotPublisher.machineData(from: machine, sortOrder: 0)
        let snapshot = GlassyDeskWidgetSnapshotBuilder().build(
            machines: [data],
            generatedAt: now
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let json = String(decoding: encoded, as: UTF8.self)

        #expect(snapshot.machines[0].displayName == "Saved Computer")
        #expect(!json.contains(host))
        #expect(!json.contains(username))
        #expect(!json.contains(macAddress))
        #expect(!json.contains(pairingID))
        #expect(!json.contains("10.20.30.40"))
        #expect(!json.contains("59001"))
    }

    @Test @MainActor
    func unchangedReachabilityUpdatesTimestampWithoutSpendingAnotherReload() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directoryURL: directory)
        let reloader = SpyWidgetTimelineReloader()
        let publisher = WidgetSnapshotPublisher(store: store, timelineReloader: reloader)
        let machine = SavedMachine(
            id: firstID,
            name: "Studio Mac",
            host: "studio.local",
            username: ""
        )

        publisher.publish(
            machines: [machine],
            reachabilityStatuses: [firstID: .reachable],
            checkedAt: now
        )
        publisher.publish(
            machines: [machine],
            reachabilityStatuses: [firstID: .reachable],
            checkedAt: now.addingTimeInterval(30)
        )

        #expect(reloader.reloadCount == 1)
        #expect(store.read()?.machines.first?.reachabilityCheckedAt == now.addingTimeInterval(30))

        publisher.publish(
            machines: [machine],
            reachabilityStatuses: [firstID: .unreachable],
            checkedAt: now.addingTimeInterval(60)
        )
        #expect(reloader.reloadCount == 2)
    }

    private func input(
        id: UUID,
        name: String,
        order: Int,
        reachability: WidgetMachineReachability? = nil
    ) -> WidgetMachineData {
        WidgetMachineData(
            id: id,
            rawName: name,
            connectionKind: .vnc,
            lastConnectedAt: nil,
            sortOrder: order,
            reachability: reachability
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassyDeskWidgetTests-\(UUID().uuidString)", isDirectory: true)
    }
}

@MainActor
private final class SpyWidgetTimelineReloader: WidgetTimelineReloading {
    private(set) var reloadCount = 0

    func reloadWidgetTimelines() {
        reloadCount += 1
    }
}

@MainActor
private final class SpyWidgetSnapshotPublisher: WidgetSnapshotPublishing {
    private(set) var publishedMachineCounts: [Int] = []

    func publish(machines: [SavedMachine]) {
        publishedMachineCounts.append(machines.count)
    }

    func publish(
        machines: [SavedMachine],
        reachabilityStatuses: [UUID: MachineReachabilityStatus],
        checkedAt: Date
    ) {
        publishedMachineCounts.append(machines.count)
    }
}

private struct SavedMachineLoadError: Error {}

private final class FlakySavedMachineRepository: SavedMachineRepository {
    var fails = false
    private let machines = [SavedMachine(name: "Studio Mac", host: "studio.local", username: "")]

    func loadMachines() -> [SavedMachine] { (try? fetchMachines()) ?? [] }
    func fetchMachines() throws -> [SavedMachine] {
        if fails { throw SavedMachineLoadError() }
        return machines
    }
    func addMachine(_ machine: SavedMachine) {}
    func updateMachine(_ machine: SavedMachine) {}
    func deleteMachine(withID id: UUID) {}
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
