import Foundation

@MainActor
protocol MachineStoring: AnyObject {
    var machines: [SavedMachine] { get }
    var recentConnections: [ConnectionHistoryEntry] { get }

    func reload()
    func add(_ machine: SavedMachine, password: String)
    @discardableResult func update(_ machine: SavedMachine, password: String) -> Bool
    @discardableResult func delete(_ machine: SavedMachine) -> Bool
    func contains(_ machine: SavedMachine) -> Bool
    func machine(withID id: UUID) -> SavedMachine?
    func password(for machine: SavedMachine) -> String
    func sessionPreferences(for machine: SavedMachine) -> SessionPreferences
    func setSessionPreferences(_ preferences: SessionPreferences, for machine: SavedMachine)
    func startSession(to machine: SavedMachine, connectedAt: Date) -> UUID
    func finishSession(withID id: UUID,
                       endedAt: Date,
                       outcome: ConnectionHistoryOutcome)
    func deleteRecentConnection(_ entry: ConnectionHistoryEntry)
    func clearRecentConnections()
}
