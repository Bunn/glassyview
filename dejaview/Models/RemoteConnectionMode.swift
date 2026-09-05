import Foundation

enum RemoteConnectionMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case vnc
    case glassyStream

    static let `default`: Self = .vnc

    static var availableCases: [Self] {
        allCases.filter(\.isEnabled)
    }

    var id: Self { self }

    var isEnabled: Bool {
        switch self {
        case .vnc:
            true
        case .glassyStream:
            FeatureFlags.isGlassyStreamEnabled
        }
    }

    var title: String {
        switch self {
        case .vnc:
            String(localized: "Standard VNC")
        case .glassyStream:
            String(localized: "Fast Connection")
        }
    }

    var description: String {
        switch self {
        case .vnc:
            String(localized: "Uses built-in macOS Screen Sharing. No extra download needed.")
        case .glassyStream:
            String(localized: "Faster, smoother control with an encrypted connection. Requires Glassy Desk for Mac, then a QR code or manual pairing.")
        }
    }

    var systemImage: String {
        switch self {
        case .vnc:
            "network"
        case .glassyStream:
            "bolt.fill"
        }
    }
}
