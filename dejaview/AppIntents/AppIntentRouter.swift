import Foundation
import Observation

@MainActor
@Observable
final class AppIntentRouter: AppIntentRouting {
    static let shared = AppIntentRouter()

    /// Navigation, connection, and reload work for exactly one active scene.
    private(set) var request: AppIntentRequest?
    /// Every scene ends its own session. A counter needs no clearing, so a
    /// scene without a session cannot consume the request for the others.
    private(set) var disconnectGeneration = 0

    init() {}

    func requestConnection(to machineID: UUID) {
        AppLog.ui.info("Received App Intent connection request for machine id=\(machineID.uuidString, privacy: .public)")
        request = AppIntentRequest(action: .connect(machineID: machineID))
    }

    func requestOpen(destination: DejaViewDestination) {
        AppLog.ui.info("Received App Intent open request for destination=\(destination.displayName, privacy: .public)")
        request = AppIntentRequest(action: .open(destination: destination))
    }

    func requestRefreshNearby() {
        AppLog.ui.info("Received App Intent nearby refresh request")
        request = AppIntentRequest(action: .refreshNearby)
    }

    func requestDisconnect() {
        AppLog.ui.info("Received App Intent disconnect request")
        disconnectGeneration += 1
    }

    func requestMachinesReload() {
        AppLog.ui.info("Received App Intent machine reload request")
        request = AppIntentRequest(action: .reloadMachines)
    }

    func claim(_ pendingRequest: AppIntentRequest) -> Bool {
        guard request == pendingRequest else { return false }
        request = nil
        return true
    }
}
