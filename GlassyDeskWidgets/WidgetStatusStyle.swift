import SwiftUI

func statusTitle(_ status: WidgetMachineReachability) -> String {
    switch status {
    case .unknown:
        String(localized: "Status unknown")
    case .checking:
        String(localized: "Checking")
    case .reachable:
        String(localized: "Online")
    case .unreachable:
        String(localized: "Offline")
    }
}

func statusColor(_ status: WidgetMachineReachability) -> Color {
    switch status {
    case .unknown, .checking:
        .secondary
    case .reachable:
        .green
    case .unreachable:
        .red
    }
}
