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

struct GlassyStreamAuthentication: Equatable, Sendable {
    let hostIdentifier: Data
    let hostName: String
    let maximumMediaPayloadLength: Int
    let resumedSession: Bool
}

enum GlassyStreamEvent: Equatable, Sendable {
    case authenticated(GlassyStreamAuthentication)
    case videoConfiguration(GlassyStreamVideoConfiguration)
    case videoAccessUnit(GlassyStreamVideoAccessUnit)
    case pong(Data)
}

/// Everything required to open one Glassy Stream connection.
///
/// Pass the raw twelve-symbol value from ``GlassyHostPairingCode``. Hyphens
/// are also accepted defensively, but are removed before authentication. When
/// `pairingCode` is nil, the client attempts secure resume from Keychain.
struct GlassyStreamConnectionConfiguration: @unchecked Sendable {
    let endpoint: NWEndpoint
    let savedMachineID: UUID
    let pairingCode: String?
    let expectedHostIdentifier: Data?
    let clientName: String
    let authenticationTimeout: TimeInterval

    init(endpoint: NWEndpoint,
         savedMachineID: UUID,
         pairingCode: String? = nil,
         expectedHostIdentifier: Data? = nil,
         clientName: String = ProcessInfo.processInfo.hostName,
         authenticationTimeout: TimeInterval = 10) {
        self.endpoint = endpoint
        self.savedMachineID = savedMachineID
        self.pairingCode = pairingCode
        self.expectedHostIdentifier = expectedHostIdentifier
        self.clientName = clientName
        self.authenticationTimeout = authenticationTimeout
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
    case authenticationRejected(String)
    case hostIdentityMismatch
    case directInputUnsupported
    case unsupportedHostVersion(UInt8)
    case protocolViolation(String)
    case credentialStoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyConnecting:
            "A Glassy Stream connection is already active."
        case .cancelled:
            "The Glassy Stream connection was cancelled."
        case let .connectionFailed(message):
            "Could not connect to Glassy Host: \(message)"
        case .connectionClosed:
            "Glassy Host closed the connection."
        case .authenticationTimedOut:
            "Glassy Host did not complete the secure connection in time."
        case let .pairingCodeRequired(hostName):
            "Enter the pairing code shown by \(hostName)."
        case .invalidPairingCode:
            "The pairing code must contain twelve valid symbols."
        case let .authenticationRejected(message):
            "Glassy Host rejected authentication: \(message)"
        case .hostIdentityMismatch:
            "This Glassy Host is not the Mac paired with this saved machine."
        case .directInputUnsupported:
            "This version of Glassy Host does not support secure keyboard and pointer input. Update Glassy Host and try again."
        case let .unsupportedHostVersion(version):
            "Glassy Host protocol version \(version) is not supported."
        case let .protocolViolation(message):
            "Glassy Host sent an invalid message: \(message)"
        case let .credentialStoreFailed(message):
            "Could not access the Glassy Stream credential: \(message)"
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
