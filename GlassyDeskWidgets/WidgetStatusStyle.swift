import SwiftUI

func statusTitle(_ status: WidgetMachineReachability) -> String {
    switch status {
    case .unknown:
        "Status unknown"
    case .checking:
        "Checking"
    case .reachable:
        "Online"
    case .unreachable:
        "Offline"
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
