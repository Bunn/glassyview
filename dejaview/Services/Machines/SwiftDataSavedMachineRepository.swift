import Foundation
import SwiftData

/// Creates short-lived model contexts per operation and uses a lock around
/// one-time migration, so the shared repository can cross Swift 6 boundaries.
final class SwiftDataSavedMachineRepository: SavedMachineRepository, @unchecked Sendable {
    static let shared = SwiftDataSavedMachineRepository()

    private let modelContainer: ModelContainer
    private let legacyRepository: UserDefaultsSavedMachineRepository
    private let migrationLock = NSLock()
    private let migrationCompletedKey = "savedMachinesSwiftDataMigrationCompleted"
    private let maximumHistoryCount = 100

    init(modelContainer: ModelContainer = DejaViewModelContainer.shared,
         legacyRepository: UserDefaultsSavedMachineRepository = .shared) {
        self.modelContainer = modelContainer
        self.legacyRepository = legacyRepository
    }

    func loadMachines() -> [SavedMachine] {
        do {
            return try fetchMachines()
        } catch {
            AppLog.storage.error("Failed to fetch saved machines from SwiftData: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func fetchMachines() throws -> [SavedMachine] {
        performLegacyMigrationIfNeeded()

        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<SavedMachineRecord>(
            sortBy: [
                SortDescriptor(\SavedMachineRecord.sortOrder),
                SortDescriptor(\SavedMachineRecord.createdAt),
                SortDescriptor(\SavedMachineRecord.name)
            ]
        )

        let records = try context.fetch(descriptor)
        AppLog.storage.info("Loaded \(records.count, privacy: .public) saved machines from SwiftData")
        return records.map(\.savedMachine)
    }

    func addMachine(_ machine: SavedMachine) {
        performLegacyMigrationIfNeeded()

        let context = ModelContext(modelContainer)
        let nextSortOrder = nextSortOrder(in: context)
        let record = SavedMachineRecord(machine: machine, sortOrder: nextSortOrder)
        context.insert(record)
        save(context)
    }

    func updateMachine(_ machine: SavedMachine) {
        performLegacyMigrationIfNeeded()

        let context = ModelContext(modelContainer)

        if let record = machineRecord(withID: machine.id, in: context) {
            record.update(from: machine)
        } else {
            AppLog.storage.warning("SwiftData record missing for update; inserting machine id=\(machine.id.uuidString, privacy: .public)")
            context.insert(SavedMachineRecord(machine: machine, sortOrder: nextSortOrder(in: context)))
        }

        save(context)
    }

    func deleteMachine(withID id: UUID) {
        performLegacyMigrationIfNeeded()

        let context = ModelContext(modelContainer)

        guard let record = machineRecord(withID: id, in: context) else {
            AppLog.storage.warning("Attempted to delete missing SwiftData machine id=\(id.uuidString, privacy: .public)")
            return
        }

        context.delete(record)
        save(context)
    }

    func loadRecentConnections(limit: Int) -> [ConnectionHistoryEntry] {
        performLegacyMigrationIfNeeded()

        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<ConnectionHistoryRecord>(
            sortBy: [SortDescriptor(\ConnectionHistoryRecord.connectedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        do {
            let records = try context.fetch(descriptor)
            AppLog.storage.info("Loaded connection history from SwiftData; requestedLimit=\(limit, privacy: .public) count=\(records.count, privacy: .public) records=\(self.connectionHistorySummary(records), privacy: .public)")
            return records.map(\.entry)
        } catch {
            AppLog.storage.error("Failed to fetch connection history from SwiftData; \(self.errorSummary(error), privacy: .public)")
            return []
        }
    }

    func startSession(withID id: UUID,
                      to machine: SavedMachine,
                      connectedAt: Date) {
        performLegacyMigrationIfNeeded()

        let context = ModelContext(modelContainer)
        let savedRecord = machineRecord(withID: machine.id, in: context)

        savedRecord?.lastConnectedAt = connectedAt
        savedRecord?.updatedAt = connectedAt

        let historyRecord = ConnectionHistoryRecord(id: id,
                                                    machine: machine,
                                                    machineID: savedRecord?.id,
                                                    connectedAt: connectedAt)
        context.insert(historyRecord)
        AppLog.storage.info("Inserted session history into ModelContext; id=\(id.uuidString, privacy: .public) savedMachineMatched=\(savedRecord != nil, privacy: .public) connectedAt=\(connectedAt.timeIntervalSince1970, privacy: .public)")
        pruneConnectionHistory(in: context)

        if save(context, operation: "startSession") {
            logConnectionHistorySnapshot(reason: "afterStartSessionSave")
        }
    }

    func finishSession(withID id: UUID,
                       endedAt: Date,
                       outcome: ConnectionHistoryOutcome) {
        performLegacyMigrationIfNeeded()

        let context = ModelContext(modelContainer)

        guard let record = connectionHistoryRecord(withID: id, in: context) else {
            AppLog.storage.warning("Could not finalize missing connection history id=\(id.uuidString, privacy: .public)")
            logConnectionHistorySnapshot(reason: "finishSessionRecordMissing")
            return
        }

        record.finish(at: endedAt, outcome: outcome)
        AppLog.storage.info("Updated session history before final save; id=\(id.uuidString, privacy: .public) endedAt=\(endedAt.timeIntervalSince1970, privacy: .public) outcome=\(outcome.rawValue, privacy: .public)")

        if save(context, operation: "finishSession") {
            logConnectionHistorySnapshot(reason: "afterFinishSessionSave")
        }
    }

    func deleteRecentConnection(withID id: UUID) {
        performLegacyMigrationIfNeeded()

        let context = ModelContext(modelContainer)

        guard let record = connectionHistoryRecord(withID: id, in: context) else {
            AppLog.storage.warning("Attempted to delete missing connection history id=\(id.uuidString, privacy: .public)")
            return
        }

        context.delete(record)
        save(context)
    }

    func clearRecentConnections() {
        performLegacyMigrationIfNeeded()

        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<ConnectionHistoryRecord>()

        do {
            let records = try context.fetch(descriptor)
            records.forEach(context.delete)
            save(context)
        } catch {
            AppLog.storage.error("Failed to clear connection history: \(error.localizedDescription, privacy: .public)")
        }
    }

    func password(for id: UUID) -> String? {
        performLegacyMigrationIfNeeded()

        let context = ModelContext(modelContainer)

        guard let record = machineRecord(withID: id, in: context) else {
            return legacyRepository.password(for: id)
        }

        if let password = record.password {
            return password
        }

        guard let legacyPassword = legacyRepository.password(for: id) else {
            return nil
        }

        record.password = legacyPassword
        record.updatedAt = .now
        save(context)

        return legacyPassword
    }

    func setPassword(_ password: String, for id: UUID) {
        performLegacyMigrationIfNeeded()

        let context = ModelContext(modelContainer)

        guard let record = machineRecord(withID: id, in: context) else {
            AppLog.storage.warning("Attempted to set password for missing SwiftData machine id=\(id.uuidString, privacy: .public)")
            legacyRepository.setPassword(password, for: id)
            return
        }

        record.password = password
        record.updatedAt = .now
        save(context)
        legacyRepository.setPassword(password, for: id)
    }

    func deletePassword(for id: UUID) {
        performLegacyMigrationIfNeeded()

        let context = ModelContext(modelContainer)

        if let record = machineRecord(withID: id, in: context) {
            record.password = nil
            record.updatedAt = .now
            save(context)
        }

        legacyRepository.deletePassword(for: id)
    }

    func sessionPreferences(for id: UUID) -> SessionPreferences {
        performLegacyMigrationIfNeeded()

        let context = ModelContext(modelContainer)

        guard let record = machineRecord(withID: id, in: context) else {
            AppLog.storage.warning("Session preferences requested for missing SwiftData machine id=\(id.uuidString, privacy: .public)")
            return legacyRepository.sessionPreferences(for: id)
        }

        guard let data = record.sessionPreferencesData else {
            return .default
        }

        do {
            return try JSONDecoder().decode(SessionPreferences.self, from: data).normalized
        } catch {
            AppLog.storage.error("Failed to decode SwiftData session preferences id=\(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .default
        }
    }

    func setSessionPreferences(_ preferences: SessionPreferences, for id: UUID) {
        performLegacyMigrationIfNeeded()

        let context = ModelContext(modelContainer)

        guard let record = machineRecord(withID: id, in: context) else {
            AppLog.storage.warning("Attempted to save session preferences for missing SwiftData machine id=\(id.uuidString, privacy: .public)")
            return
        }

        do {
            record.sessionPreferencesData = try JSONEncoder().encode(preferences.normalized)
            record.updatedAt = .now
            save(context, operation: "setSessionPreferences")
        } catch {
            AppLog.storage.error("Failed to encode SwiftData session preferences id=\(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func performLegacyMigrationIfNeeded() {
        migrationLock.lock()
        defer { migrationLock.unlock() }

        let defaults = UserDefaults.standard

        guard !defaults.bool(forKey: migrationCompletedKey) else { return }

        let legacyMachines = legacyRepository.loadMachines()

        guard !legacyMachines.isEmpty else {
            defaults.set(true, forKey: migrationCompletedKey)
            return
        }

        let context = ModelContext(modelContainer)
        var insertedCount = 0

        for (index, machine) in legacyMachines.enumerated() where machineRecord(withID: machine.id, in: context) == nil {
            let legacyPassword = legacyRepository.password(for: machine.id)
            context.insert(SavedMachineRecord(machine: machine,
                                              password: legacyPassword,
                                              sortOrder: index))
            insertedCount += 1
        }

        do {
            try context.save()
            defaults.set(true, forKey: migrationCompletedKey)
            AppLog.storage.info("Migrated \(insertedCount, privacy: .public) saved machines from UserDefaults to SwiftData")
        } catch {
            AppLog.storage.error("Failed to migrate saved machines to SwiftData: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func machineRecord(withID id: UUID, in context: ModelContext) -> SavedMachineRecord? {
        var descriptor = FetchDescriptor<SavedMachineRecord>(
            predicate: #Predicate<SavedMachineRecord> { record in
                record.id == id
            }
        )
        descriptor.fetchLimit = 1

        do {
            return try context.fetch(descriptor).first
        } catch {
            AppLog.storage.error("Failed to fetch saved machine id=\(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func connectionHistoryRecord(withID id: UUID,
                                         in context: ModelContext) -> ConnectionHistoryRecord? {
        var descriptor = FetchDescriptor<ConnectionHistoryRecord>(
            predicate: #Predicate<ConnectionHistoryRecord> { record in
                record.id == id
            }
        )
        descriptor.fetchLimit = 1

        do {
            if let record = try context.fetch(descriptor).first {
                AppLog.storage.info("Found connection history by predicate; id=\(id.uuidString, privacy: .public)")
                return record
            }

            let allRecords = try context.fetch(FetchDescriptor<ConnectionHistoryRecord>())

            if let record = allRecords.first(where: { $0.id == id }) {
                AppLog.storage.warning("Connection history predicate missed an existing record; using in-memory fallback id=\(id.uuidString, privacy: .public) totalCount=\(allRecords.count, privacy: .public)")
                return record
            }

            AppLog.storage.warning("Connection history lookup returned no record; requestedID=\(id.uuidString, privacy: .public) totalCount=\(allRecords.count, privacy: .public) records=\(self.connectionHistorySummary(allRecords), privacy: .public)")
            return nil
        } catch {
            AppLog.storage.error("Failed to fetch connection history id=\(id.uuidString, privacy: .public); \(self.errorSummary(error), privacy: .public)")
            return nil
        }
    }

    private func nextSortOrder(in context: ModelContext) -> Int {
        var descriptor = FetchDescriptor<SavedMachineRecord>(
            sortBy: [SortDescriptor(\SavedMachineRecord.sortOrder, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        do {
            return (try context.fetch(descriptor).first?.sortOrder ?? -1) + 1
        } catch {
            AppLog.storage.error("Failed to compute next machine sort order: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    private func pruneConnectionHistory(in context: ModelContext) {
        let descriptor = FetchDescriptor<ConnectionHistoryRecord>(
            sortBy: [SortDescriptor(\ConnectionHistoryRecord.connectedAt, order: .reverse)]
        )

        do {
            // SwiftData can apply `fetchOffset` incorrectly when the context has
            // pending inserts, which caused a brand-new first record to be
            // returned as stale and deleted. Select the overflow explicitly.
            let allRecords = try context.fetch(descriptor)
            let staleRecords = Array(allRecords.dropFirst(maximumHistoryCount))
            AppLog.storage.info("Evaluated connection history pruning; maximumCount=\(self.maximumHistoryCount, privacy: .public) totalCount=\(allRecords.count, privacy: .public) staleCount=\(staleRecords.count, privacy: .public) staleRecords=\(self.connectionHistorySummary(staleRecords), privacy: .public)")
            staleRecords.forEach(context.delete)
        } catch {
            AppLog.storage.error("Failed to prune connection history; \(self.errorSummary(error), privacy: .public)")
        }
    }

    private func logConnectionHistorySnapshot(reason: String) {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<ConnectionHistoryRecord>(
            sortBy: [SortDescriptor(\ConnectionHistoryRecord.connectedAt, order: .reverse)]
        )

        do {
            let records = try context.fetch(descriptor)
            AppLog.storage.info("Connection history snapshot; reason=\(reason, privacy: .public) count=\(records.count, privacy: .public) records=\(self.connectionHistorySummary(records), privacy: .public)")
        } catch {
            AppLog.storage.error("Failed to inspect connection history; reason=\(reason, privacy: .public) \(self.errorSummary(error), privacy: .public)")
        }
    }

    private func connectionHistorySummary(_ records: [ConnectionHistoryRecord]) -> String {
        guard !records.isEmpty else { return "none" }

        return records.map { record in
            "id=\(record.id.uuidString),finished=\(record.endedAt != nil),outcome=\(record.outcomeRawValue)"
        }
        .joined(separator: ";")
    }

    private func errorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        return "domain=\(nsError.domain),code=\(nsError.code),description=\(nsError.localizedDescription),debug=\(String(reflecting: error))"
    }

    @discardableResult
    private func save(_ context: ModelContext,
                      operation: String = "repositoryMutation") -> Bool {
        do {
            try context.save()
            AppLog.storage.info("Saved SwiftData changes; operation=\(operation, privacy: .public)")
            return true
        } catch {
            AppLog.storage.error("Failed to save SwiftData changes; operation=\(operation, privacy: .public) \(self.errorSummary(error), privacy: .public)")
            return false
        }
    }
}
