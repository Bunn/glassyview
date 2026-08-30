import Foundation
import RoyalVNCKit

enum RemoteModifierKey: String, CaseIterable, Identifiable, Hashable {
    case command
    case shift
    case option
    case control

    var id: String { rawValue }

    var title: String {
        switch self {
        case .command:
            String(localized: "Cmd")
        case .shift:
            String(localized: "Shift")
        case .option:
            String(localized: "Opt")
        case .control:
            String(localized: "Ctrl")
        }
    }

    var keyCode: VNCKeyCode {
        switch self {
        case .command:
            .command
        case .shift:
            .shift
        case .option:
            .option
        case .control:
            .control
        }
    }
}
