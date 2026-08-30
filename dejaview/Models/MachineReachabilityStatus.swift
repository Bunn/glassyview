import Foundation

enum MachineReachabilityStatus: Equatable, Sendable {
    case checking
    case waking
    case reachable
    case unreachable

    var title: String {
        switch self {
        case .checking:
            String(localized: "Checking")
        case .waking:
            String(localized: "Waking")
        case .reachable:
            String(localized: "Reachable")
        case .unreachable:
            String(localized: "Unreachable")
        }
    }
}
