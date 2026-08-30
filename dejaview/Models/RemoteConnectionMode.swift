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
            "VNC"
        case .glassyStream:
            "Glassy Stream"
        }
    }

    var description: String {
        switch self {
        case .vnc:
            "Uses standard Screen Sharing. This is the default and does not require the Glassy Host companion app."
        case .glassyStream:
            "Uses the faster encrypted Glassy Host video and input stream. It requires the macOS companion app and asks for a pairing code or configured password the first time."
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
