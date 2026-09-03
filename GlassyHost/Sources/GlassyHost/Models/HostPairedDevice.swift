import Foundation

struct HostPairedDevice: Identifiable, Equatable, Sendable {
    let id: Data
    let name: String
    let lastConnectedAt: Date
    let isConnected: Bool
}
