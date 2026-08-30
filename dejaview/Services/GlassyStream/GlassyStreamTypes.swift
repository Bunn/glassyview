import Foundation
import Network

/// The H.264 decoder configuration sent by Glassy Host.
struct GlassyStreamVideoConfiguration: Equatable, Sendable {
    let nalUnitHeaderLength: Int
    let parameterSets: [Data]
}

/// One AVCC-formatted H.264 access unit sent by Glassy Host.
struct GlassyStreamVideoAccessUnit: Equatable, Sendable {
    let data: Data
    let presentationTime: TimeInterval
    let duration: TimeInterval?
    let isKeyFrame: Bool
}

/// A host cursor location normalized across the complete UInt16 range.
struct GlassyStreamCursorPosition: Equatable, Sendable {
    let x: UInt16
    let y: UInt16
}

struct GlassyStreamAuthentication: Equatable, Sendable {
    let hostIdentifier: Data
    let hostName: String
    let maximumMediaPayloadLength: Int
    let resumedSession: Bool
    let supportsStreamQuality: Bool
    let supportsCursorPositionUpdates: Bool
}

enum GlassyStreamEvent: Equatable, Sendable {
    case authenticated(GlassyStreamAuthentication)
    case videoConfiguration(GlassyStreamVideoConfiguration)
    case videoAccessUnit(GlassyStreamVideoAccessUnit)
    case cursorPosition(GlassyStreamCursorPosition)
    case pong(Data)
}

/// A first-use credential supplied explicitly by the user. Once the host has
/// authenticated, this value is discarded and subsequent connections use the
/// random per-device resume secret stored in Keychain.
enum GlassyStreamBootstrapCredential: Sendable {
    case oneTimeCode(String)
    case password(String)
}

/// Everything required to open one Glassy Stream connection.
///
/// Pass a first-use code or password as `bootstrapCredential`. When it is nil,
/// the client attempts secure resume from Keychain.
struct GlassyStreamConnectionConfiguration: @unchecked Sendable {
    let endpoint: NWEndpoint
    let savedMachineID: UUID
    let bootstrapCredential: GlassyStreamBootstrapCredential?
    let expectedHostIdentifier: Data?
    let desiredQuality: RemoteSessionQuality
    let clientName: String
    let authenticationTimeout: TimeInterval

    init(endpoint: NWEndpoint,
         savedMachineID: UUID,
         bootstrapCredential: GlassyStreamBootstrapCredential? = nil,
         expectedHostIdentifier: Data? = nil,
         desiredQuality: RemoteSessionQuality = .best,
         clientName: String = ProcessInfo.processInfo.hostName,
         authenticationTimeout: TimeInterval = 10) {
        self.endpoint = endpoint
        self.savedMachineID = savedMachineID
        self.bootstrapCredential = bootstrapCredential
        self.expectedHostIdentifier = expectedHostIdentifier
        self.desiredQuality = desiredQuality
        self.clientName = clientName
        self.authenticationTimeout = authenticationTimeout
    }

    func withoutBootstrapCredential() -> Self {
        Self(
            endpoint: endpoint,
            savedMachineID: savedMachineID,
            bootstrapCredential: nil,
            expectedHostIdentifier: expectedHostIdentifier,
            desiredQuality: desiredQuality,
            clientName: clientName,
            authenticationTimeout: authenticationTimeout
        )
    }
}

struct GlassyStreamPointerButtons: OptionSet, Sendable {
    let rawValue: UInt8

    static let left = GlassyStreamPointerButtons(rawValue: 1 << 0)
    static let right = GlassyStreamPointerButtons(rawValue: 1 << 1)
}

enum GlassyStreamScrollDirection: UInt8, Sendable {
    case up = 0
    case down = 1
    case left = 2
    case right = 3
}

struct GlassyStreamTextModifiers: OptionSet, Sendable {
    let rawValue: UInt8

    static let command = GlassyStreamTextModifiers(rawValue: 1 << 0)
    static let shift = GlassyStreamTextModifiers(rawValue: 1 << 1)
    static let option = GlassyStreamTextModifiers(rawValue: 1 << 2)
    static let control = GlassyStreamTextModifiers(rawValue: 1 << 3)
}

enum GlassyStreamClientError: Error, LocalizedError, Sendable {
    case alreadyConnecting
    case cancelled
    case connectionFailed(String)
    case connectionClosed
    case authenticationTimedOut
    case pairingCodeRequired(hostName: String)
    case invalidPairingCode
    case invalidPairingPassword
    case pairingPasswordRequiresTailscale
    case pairingPasswordUnsupported
    case pairingPasswordDerivationFailed(Int32)
    case authenticationRejected(String)
    case hostIdentityMismatch
    case directInputUnsupported
    case unsupportedHostVersion(UInt8)
    case protocolViolation(String)
    case credentialStoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyConnecting:
            String(localized: "A Glassy Stream connection is already active.")
        case .cancelled:
            String(localized: "The Glassy Stream connection was cancelled.")
        case let .connectionFailed(message):
            String(localized: "Could not connect to Glassy Host: \(message)")
        case .connectionClosed:
            String(localized: "Glassy Host closed the connection.")
        case .authenticationTimedOut:
            String(localized: "Glassy Host did not complete the secure connection in time.")
        case let .pairingCodeRequired(hostName):
            String(localized: "Enter the pairing code shown by \(hostName).")
        case .invalidPairingCode:
            String(localized: "The pairing code must contain twelve valid symbols.")
        case .invalidPairingPassword:
            String(localized: "The pairing password must be 15 through 128 characters and cannot contain control characters or line breaks.")
        case .pairingPasswordRequiresTailscale:
            String(localized: "Reusable-password pairing requires an active Tailscale VPN route and a saved Tailscale IP or full .ts.net address.")
        case .pairingPasswordUnsupported:
            String(localized: "This Glassy Host does not support password pairing.")
        case let .pairingPasswordDerivationFailed(status):
            String(localized: "The pairing password could not be prepared securely (status \(status)).")
        case let .authenticationRejected(message):
            String(localized: "Glassy Host rejected authentication: \(message)")
        case .hostIdentityMismatch:
            String(localized: "This Glassy Host is not the Mac paired with this saved machine.")
        case .directInputUnsupported:
            String(localized: "This version of Glassy Host does not support secure keyboard and pointer input. Update Glassy Host and try again.")
        case let .unsupportedHostVersion(version):
            String(localized: "Glassy Host protocol version \(version) is not supported.")
        case let .protocolViolation(message):
            String(localized: "Glassy Host sent an invalid message: \(message)")
        case let .credentialStoreFailed(message):
            String(localized: "Could not access the Glassy Stream credential: \(message)")
        }
    }
}

/// Ordered callbacks for the low-latency transport. The callback queue is
/// chosen by the caller; a dedicated renderer queue avoids unnecessary hops
/// through the main actor for 60 fps video.
struct GlassyStreamClientCallbacks: Sendable {
    let onEvent: @Sendable (GlassyStreamEvent) -> Void
    let onCompletion: @Sendable (Result<Void, GlassyStreamClientError>) -> Void

    init(onEvent: @escaping @Sendable (GlassyStreamEvent) -> Void,
         onCompletion: @escaping @Sendable (Result<Void, GlassyStreamClientError>) -> Void) {
        self.onEvent = onEvent
        self.onCompletion = onCompletion
    }
}
