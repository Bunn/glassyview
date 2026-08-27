import Foundation

enum RemoteConnectionMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case vncOnly

    static let storageKey = "remoteConnectionMode"
    static let `default`: Self = .automatic

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic:
            "Automatic"
        case .vncOnly:
            "VNC Only"
        }
    }

    var description: String {
        switch self {
        case .automatic:
            "Uses Glassy Host for low-latency streaming when available and automatically falls back to VNC."
        case .vncOnly:
            "Always uses standard VNC, even when Glassy Host is available."
        }
    }

    var systemImage: String {
        switch self {
        case .automatic:
            "bolt.fill"
        case .vncOnly:
            "network"
        }
    }
}
