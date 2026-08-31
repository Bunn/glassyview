import Foundation
import Observation
import OSLog

/// Persists saved machines and their Keychain-backed passwords.
@MainActor
@Observable
final class MachineStore: MachineStoring {
    private(set) var machines: [SavedMachine] = []
    private(set) var recentConnections: [ConnectionHistoryEntry] = []

    @ObservationIgnored private let repository: SavedMachineRepository
    @ObservationIgnored private let recentConnectionLimit = 50

    init(repository: SavedMachineRepository = SwiftDataSavedMachineRepository.shared) {
        self.repository = repository
        reload()
    }

    func reload() {
        let loadedMachines = repository.loadMachines()
        let loadedRecentConnections = repository.loadRecentConnections(limit: recentConnectionLimit)
        machines = loadedMachines
        recentConnections = loadedRecentConnections

        let recentIDs = loadedRecentConnections.isEmpty
            ? "none"
            : loadedRecentConnections.map { $0.id.uuidString }.joined(separator: ",")
        AppLog.storage.info("Machine store reloaded; machineCount=\(loadedMachines.count, privacy: .public) recentCount=\(loadedRecentConnections.count, privacy: .public) recentIDs=\(recentIDs, privacy: .public)")
    }

    func add(_ machine: SavedMachine, password: String) {
        AppLog.storage.info("Adding saved machine '\(machine.displayName, privacy: .public)' at \(machine.host, privacy: .public):\(machine.port, privacy: .public)")
        repository.addMachine(machine)
        repository.setPassword(password, for: machine.id)
        reload()
    }

    func update(_ machine: SavedMachine, password: String) {
        guard contains(machine) else {
            AppLog.storage.warning("Attempted to update missing machine id=\(machine.id.uuidString, privacy: .public)")
            return
        }

        AppLog.storage.info("Updating saved machine '\(machine.displayName, privacy: .public)' at \(machine.host, privacy: .public):\(machine.port, privacy: .public)")
        repository.updateMachine(machine)
        repository.setPassword(password, for: machine.id)
        reload()
    }

    func delete(_ machine: SavedMachine) {
        AppLog.storage.info("Deleting saved machine '\(machine.displayName, privacy: .public)'")
        repository.deleteMachine(withID: machine.id)
        repository.deletePassword(for: machine.id)
        reload()
    }

    func contains(_ machine: SavedMachine) -> Bool {
        machines.contains { $0.id == machine.id }
    }

    func machine(withID id: UUID) -> SavedMachine? {
        machines.first { $0.id == id }
    }

    func password(for machine: SavedMachine) -> String {
        guard let password = repository.password(for: machine.id) else {
            AppLog.storage.debug("No Keychain password found for '\(machine.displayName, privacy: .public)'")
            return ""
        }

        return password
    }

    func sessionPreferences(for machine: SavedMachine) -> SessionPreferences {
        let preferences = repository.sessionPreferences(for: machine.id)
        AppLog.storage.info("Loaded session preferences for '\(machine.displayName, privacy: .public)'; touchMode=\(preferences.touchMode.rawValue, privacy: .public) trackpadDot=\(preferences.showsTrackpadCursorDot, privacy: .public) display=\(preferences.displaySelection.logDescription, privacy: .public) zoom=\(preferences.zoomScale, privacy: .public) followsCursor=\(preferences.followsCursor, privacy: .public) frameRate=\(preferences.frameRate.rawValue, privacy: .public) quality=\(preferences.quality.rawValue, privacy: .public)")
        return preferences
    }

    func setSessionPreferences(_ preferences: SessionPreferences, for machine: SavedMachine) {
        let preferences = preferences.normalized
        AppLog.storage.info("Saving session preferences for '\(machine.displayName, privacy: .public)'; touchMode=\(preferences.touchMode.rawValue, privacy: .public) trackpadDot=\(preferences.showsTrackpadCursorDot, privacy: .public) display=\(preferences.displaySelection.logDescription, privacy: .public) zoom=\(preferences.zoomScale, privacy: .public) followsCursor=\(preferences.followsCursor, privacy: .public) frameRate=\(preferences.frameRate.rawValue, privacy: .public) quality=\(preferences.quality.rawValue, privacy: .public)")
        repository.setSessionPreferences(preferences, for: machine.id)
    }

    func startSession(to machine: SavedMachine, connectedAt: Date) -> UUID {
        let id = UUID()
        AppLog.storage.info("Recording successful session start for '\(machine.displayName, privacy: .public)'; id=\(id.uuidString, privacy: .public)")
        repository.startSession(withID: id,
                                to: machine,
                                connectedAt: connectedAt)
        reload()
        let containsNewEntry = recentConnections.contains { $0.id == id }
        AppLog.storage.info("Successful session start reload completed; id=\(id.uuidString, privacy: .public) recentCount=\(self.recentConnections.count, privacy: .public) containsNewEntry=\(containsNewEntry, privacy: .public)")
        return id
    }

    func finishSession(withID id: UUID,
                       endedAt: Date,
                       outcome: ConnectionHistoryOutcome) {
        AppLog.storage.info("Finalizing session history id=\(id.uuidString, privacy: .public); outcome=\(outcome.rawValue, privacy: .public)")
        repository.finishSession(withID: id,
                                 endedAt: endedAt,
                                 outcome: outcome)
        reload()
    }

    func deleteRecentConnection(_ entry: ConnectionHistoryEntry) {
        AppLog.storage.info("Deleting recent connection id=\(entry.id.uuidString, privacy: .public)")
        repository.deleteRecentConnection(withID: entry.id)
        reload()
    }

    func clearRecentConnections() {
        AppLog.storage.info("Clearing recent connections")
        repository.clearRecentConnections()
        reload()
    }

    // MARK: - Persistence

    static func savedMachines(repository: SavedMachineRepository = SwiftDataSavedMachineRepository.shared) -> [SavedMachine] {
        repository.loadMachines()
    }
}
