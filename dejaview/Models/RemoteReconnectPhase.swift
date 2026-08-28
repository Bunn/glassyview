import Foundation

enum RemoteReconnectPhase: Equatable, Sendable {
    case waitingForForeground
    case waitingForNetwork
    case waiting(until: Date)
    case connecting
}
