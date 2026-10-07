import Foundation

enum AppIntentAction: Equatable {
    case connect(machineID: UUID)
    case open(destination: DejaViewDestination)
    case refreshNearby
    case reloadMachines
}

struct AppIntentRequest: Equatable, Identifiable {
    let id = UUID()
    let action: AppIntentAction
}

@MainActor
protocol AppIntentRouting: AnyObject {
    var request: AppIntentRequest? { get }
    var disconnectGeneration: Int { get }

    /// Returns true for the single scene that takes ownership of the request.
    func claim(_ pendingRequest: AppIntentRequest) -> Bool
}
