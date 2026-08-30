import Foundation

enum WakeOnLANError: LocalizedError {
    case couldNotCreateSocket
    case couldNotEnableBroadcast
    case couldNotSendPacket

    var errorDescription: String? {
        switch self {
        case .couldNotCreateSocket:
            String(localized: "The network connection for Wake-on-LAN could not be created.")
        case .couldNotEnableBroadcast:
            String(localized: "This network did not allow a Wake-on-LAN broadcast.")
        case .couldNotSendPacket:
            String(localized: "The Wake-on-LAN packet could not be sent on this network.")
        }
    }
}
