import SwiftUI

enum ConnectSection: String, CaseIterable, Hashable, Identifiable {
    case hosts
    case recents
    case nearby

    var id: Self { self }

    var title: String {
        switch self {
        case .hosts:
            String(localized: "Hosts")
        case .recents:
            String(localized: "Recents")
        case .nearby:
            String(localized: "Nearby Macs")
        }
    }

    var subtitle: String {
        switch self {
        case .hosts:
            String(localized: "Saved and discovered screen sharing targets.")
        case .recents:
            String(localized: "Previously connected Macs and session details.")
        case .nearby:
            String(localized: "Macs advertising Screen Sharing on this network.")
        }
    }

    var systemImage: String {
        switch self {
        case .hosts:
            "rectangle.connected.to.line.below"
        case .recents:
            "clock.arrow.circlepath"
        case .nearby:
            "dot.radiowaves.left.and.right"
        }
    }
}
