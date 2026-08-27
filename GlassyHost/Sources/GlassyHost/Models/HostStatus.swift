import Foundation

enum HostRunState: Equatable, Sendable {
    case stopped
    case starting
    case ready
    case failed(String)

    var title: String {
        switch self {
        case .stopped:
            "Stopped"
        case .starting:
            "Starting"
        case .ready:
            "Ready"
        case .failed:
            "Needs Attention"
        }
    }
}

enum ScreenRecordingAuthorization: Equatable, Sendable {
    case unknown
    case granted
    case denied

    var title: String {
        switch self {
        case .unknown:
            "Not Checked"
        case .granted:
            "Allowed"
        case .denied:
            "Permission Required"
        }
    }
}
