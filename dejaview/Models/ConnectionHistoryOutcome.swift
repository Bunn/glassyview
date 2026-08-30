import Foundation

enum ConnectionHistoryOutcome: String, Codable, Equatable, Sendable {
    case completed
    case interrupted

    var title: String {
        switch self {
        case .completed:
            String(localized: "Completed")
        case .interrupted:
            String(localized: "Interrupted")
        }
    }

    var systemImage: String {
        switch self {
        case .completed:
            "checkmark.circle"
        case .interrupted:
            "exclamationmark.triangle"
        }
    }
}
