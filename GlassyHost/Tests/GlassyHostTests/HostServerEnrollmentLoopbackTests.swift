import CryptoKit
import Foundation
import Network
import Testing
@testable import GlassyHost

@Test("A cloud enrollment grant authenticates exactly once over a real host connection")
func cloudEnrollmentGrantLoopbackHandshake() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let pairingSecret = Data(repeating: 0xA1, count: 32)
    let clientIdentifier = Data((0..<HostProtocol.identifierLength).map(UInt8.init))
    let requestNonce = Data(repeating: 0xB2, count: HostCloudEnrollmentSchema.requestNonceLength)
    let grantStore = HostEnrollmentGrantStore()
    let deviceAccessStore = HostDeviceAccessStore(
        fileURL: temporaryDirectory.appendingPathComponent("device-access.json")
    )
    let grant = try grantStore.issue(
        clientIdentifier: clientIdentifier,
        requestNonce: requestNonce,
        expiresAt: Date().addingTimeInterval(60)
    )
    let server = HostServer(
        serviceName: "Enrollment loopback \(UUID().uuidString)",
        port: 0,
        deviceAccessStore: deviceAccessStore,
        enrollmentGrantStore: grantStore,
        cloudEnrollmentEnabled: true
    )
    defer { server.stop() }

    let listenerResult = OneShotResult<UInt16>()
    let listenerSemaphore = DispatchSemaphore(value: 0)
    server.start(pairingSecret: pairingSecret) { _ in
    } onStatusChange: { status in
        switch status {
        case let .listening(port):
            if listenerResult.resolve(.success(port)) {
                listenerSemaphore.signal()
            }
        case let .failed(message):
            if listenerResult.resolve(.failure(.network(message))) {
                listenerSemaphore.signal()
            }
        case .stopped, .starting:
            break
        }
    }

    guard listenerSemaphore.wait(timeout: .now() + 5) == .success else {
        throw EnrollmentLoopbackTestError.timeout("waiting for the host listener")
    }
    let port = try listenerResult.get()
    let connection = EnrollmentLoopbackConnection(port: port)
    defer { connection.cancel() }
    try connection.start()

    let serverFrame = try connection.receiveFrame()
    #expect(serverFrame.kind == .serverHello)
    #expect(serverFrame.flags.isEmpty)
    #expect(serverFrame.sequence == 1)
    let serverHello = try HostProtocol.decodeServerHello(serverFrame.payload)
    let capabilities = HostProtocol.Capabilities(rawValue: serverHello.capabilities)
    #expect(capabilities.contains(.cloudEnrollment))
    #expect(serverHello.hostIdentifier == HostServer.makeHostIdentifier(from: pairingSecret))

    let clientPrivateKey = try Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: Data((1...32).map(UInt8.init))
    )
    let serverPublicKey = try Curve25519.KeyAgreement.PublicKey(
        rawRepresentation: serverHello.serverPublicKey
    )
    let sharedSecret = try clientPrivateKey.sharedSecretFromKeyAgreement(with: serverPublicKey)
    let clientName = "Loopback iPad"
    let emptyProofHello = HostProtocol.ClientHello(
        clientIdentifier: clientIdentifier,
        clientNonce: Data(repeating: 0xC3, count: HostProtocol.nonceLength),
        clientPublicKey: clientPrivateKey.publicKey.rawRepresentation,
        authenticationMethod: .enrollmentGrantV1,
        pairingWindow: serverHello.pairingWindow,
        clientName: clientName,
        proof: Data()
    )
    let transcript = try HostProtocol.authenticationTranscript(
        serverHello: serverHello,
        clientHello: emptyProofHello
    )
    let authenticationKey = HostProtocol.authenticationKey(
        sharedSecret: sharedSecret,
        credential: grant,
        transcript: transcript
    )
    let clientHello = HostProtocol.ClientHello(
        clientIdentifier: clientIdentifier,
        clientNonce: emptyProofHello.clientNonce,
        clientPublicKey: emptyProofHello.clientPublicKey,
        authenticationMethod: emptyProofHello.authenticationMethod,
        pairingWindow: emptyProofHello.pairingWindow,
        clientName: emptyProofHello.clientName,
        proof: Data(HMAC<SHA256>.authenticationCode(
            for: transcript,
            using: authenticationKey
        ))
    )
    try connection.send(HostProtocol.encode(HostProtocol.Frame(
        kind: .clientHello,
        flags: [],
        sequence: 1,
        payload: try HostProtocol.encodeClientHello(clientHello)
    )))

    let acceptedFrame = try connection.receiveFrame()
    #expect(acceptedFrame.kind == .authenticationAccepted)
    #expect(acceptedFrame.flags == [.encrypted])
    #expect(acceptedFrame.sequence == 2)
    let sessionMaterial = HostProtocol.sessionMaterial(
        sharedSecret: sharedSecret,
        credential: grant,
        transcript: transcript
    )
    let acceptedPayload = try HostProtocol.open(
        acceptedFrame.payload,
        kind: acceptedFrame.kind,
        flags: acceptedFrame.flags,
        sequence: acceptedFrame.sequence,
        material: sessionMaterial,
        serverToClient: true
    )
    let accepted = try decodeAuthenticationAccepted(acceptedPayload)
    let expectedResumeSecret = try deviceAccessStore.resumeSecret(
        rootSecret: SymmetricKey(data: pairingSecret),
        identifier: clientIdentifier
    )

    #expect(accepted.clientIdentifier == clientIdentifier)
    #expect(accepted.resumeSecret == expectedResumeSecret)
    #expect(accepted.serverTimeMilliseconds > 0)
    #expect(accepted.maximumMediaPayloadLength == UInt32(HostProtocol.maximumPayloadLength))
    #expect(throws: HostProtocol.ProtocolError.self) {
        try grantStore.credential(clientIdentifier: clientIdentifier)
    }

    let registeredDevice = try #require(server.pairedDevices.first)
    #expect(server.pairedDevices.count == 1)
    #expect(registeredDevice.id == clientIdentifier)
    #expect(registeredDevice.name == clientName)
}

private struct DecodedAuthenticationAccepted {
    let clientIdentifier: Data
    let resumeSecret: Data
    let serverTimeMilliseconds: UInt64
    let maximumMediaPayloadLength: UInt32
}

private func decodeAuthenticationAccepted(
    _ data: Data
) throws -> DecodedAuthenticationAccepted {
    let expectedLength = HostProtocol.identifierLength
        + HostProtocol.resumeSecretLength
        + MemoryLayout<UInt64>.size
        + MemoryLayout<UInt32>.size
    guard data.count == expectedLength else {
        throw EnrollmentLoopbackTestError.malformedAcceptance
    }

    var offset = 0
    func take(_ count: Int) -> Data {
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    func unsignedInteger<T: FixedWidthInteger>(_ type: T.Type) -> T {
        take(MemoryLayout<T>.size).reduce(into: T.zero) { value, byte in
            value = (value << 8) | T(byte)
        }
    }

    return DecodedAuthenticationAccepted(
        clientIdentifier: take(HostProtocol.identifierLength),
        resumeSecret: take(HostProtocol.resumeSecretLength),
        serverTimeMilliseconds: unsignedInteger(UInt64.self),
        maximumMediaPayloadLength: unsignedInteger(UInt32.self)
    )
}

private final class EnrollmentLoopbackConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "HostServerEnrollmentLoopbackTests.connection")
    private var receiveBuffer = Data()

    init(port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    func start() throws {
        let result = OneShotResult<Void>()
        let semaphore = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if result.resolve(.success(())) {
                    semaphore.signal()
                }
            case let .failed(error):
                if result.resolve(.failure(.network(error.localizedDescription))) {
                    semaphore.signal()
                }
            case .cancelled:
                if result.resolve(.failure(.network("connection cancelled"))) {
                    semaphore.signal()
                }
            case .setup, .preparing, .waiting:
                break
            @unknown default:
                if result.resolve(.failure(.network("unknown connection state"))) {
                    semaphore.signal()
                }
            }
        }
        connection.start(queue: queue)
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw EnrollmentLoopbackTestError.timeout("connecting to the host")
        }
        try result.get()
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    func send(_ data: Data) throws {
        let result = OneShotResult<Void>()
        let semaphore = DispatchSemaphore(value: 0)
        connection.send(content: data, completion: .contentProcessed { error in
            let value: Result<Void, EnrollmentLoopbackTestError> = if let error {
                .failure(.network(error.localizedDescription))
            } else {
                .success(())
            }
            if result.resolve(value) {
                semaphore.signal()
            }
        })
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw EnrollmentLoopbackTestError.timeout("sending a frame")
        }
        try result.get()
    }

    func receiveFrame() throws -> HostProtocol.Frame {
        while true {
            if let frame = try HostProtocol.decodeNextFrame(from: &receiveBuffer) {
                return frame
            }
            receiveBuffer.append(try receiveChunk())
        }
    }

    private func receiveChunk() throws -> Data {
        let result = OneShotResult<Data>()
        let semaphore = DispatchSemaphore(value: 0)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            data, _, isComplete, error in
            let value: Result<Data, EnrollmentLoopbackTestError>
            if let error {
                value = .failure(.network(error.localizedDescription))
            } else if let data, !data.isEmpty {
                value = .success(data)
            } else if isComplete {
                value = .failure(.network("connection closed before a complete frame arrived"))
            } else {
                value = .failure(.network("connection produced no data"))
            }
            if result.resolve(value) {
                semaphore.signal()
            }
        }
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw EnrollmentLoopbackTestError.timeout("receiving a frame")
        }
        return try result.get()
    }
}

private final class OneShotResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, EnrollmentLoopbackTestError>?

    @discardableResult
    func resolve(_ result: Result<Value, EnrollmentLoopbackTestError>) -> Bool {
        lock.withLock {
            guard self.result == nil else { return false }
            self.result = result
            return true
        }
    }

    func get() throws -> Value {
        try lock.withLock {
            guard let result else {
                throw EnrollmentLoopbackTestError.missingResult
            }
            return try result.get()
        }
    }
}

private enum EnrollmentLoopbackTestError: Error {
    case malformedAcceptance
    case missingResult
    case network(String)
    case timeout(String)
}
