import CryptoKit
import Foundation
import Network
import Testing
@testable import GlassyDesk

struct GlassyStreamRouteLoopbackTests {
    @Test
    func syncedMachineWithoutLocalCredentialRequestsPairingThenReconnects() async throws {
        let hostID = Data(repeating: 0x42, count: 16)
        let host = try LoopbackPairingHost(hostID: hostID, behavior: "valid")
        defer { host.stop() }
        let endpoint = try await host.start()
        let client = GlassyStreamClient(credentialStore: RouteTestCredentialStore())
        defer { client.disconnect() }
        let machineID = UUID()

        do {
            _ = try await authenticate(
                client,
                configuration: GlassyStreamConnectionConfiguration(
                    endpoint: endpoint,
                    savedMachineID: machineID,
                    expectedHostIdentifier: hostID
                )
            )
            Issue.record("A synced machine without this device's credential should request pairing")
        } catch let GlassyStreamClientError.pairingCodeRequired(hostName) {
            #expect(hostName == "Fixture Mac")
        } catch {
            Issue.record("Expected a pairing request, received \(error)")
        }

        #expect(host.proofCount == 0)
        let authentication = try await authenticate(
            client,
            configuration: GlassyStreamConnectionConfiguration(
                endpoint: endpoint,
                savedMachineID: machineID,
                bootstrapCredential: .oneTimeCode("ABCDEFGH2345"),
                expectedHostIdentifier: hostID
            )
        )
        #expect(authentication.hostIdentifier == hostID)
        #expect(!authentication.resumedSession)
        #expect(host.proofCount == 1)
    }

    /// Exercises the real NWConnection handoff and encrypted handshake: the
    /// same rotating code must produce just one ClientHello, on the winner.
    @Test(arguments: ["silent", "wrong-host", "late-hello"])
    func onlyWinningRouteReceivesBootstrapProof(firstBehavior: String) async throws {
        let hostID = Data(repeating: 0x42, count: 16)
        let primary = try LoopbackPairingHost(
            hostID: firstBehavior == "wrong-host" ? Data(repeating: 0x99, count: 16) : hostID,
            behavior: firstBehavior
        )
        let fallback = try LoopbackPairingHost(hostID: hostID, behavior: "valid")
        defer { primary.stop(); fallback.stop() }
        let primaryEndpoint = try await primary.start()
        let fallbackEndpoint = try await fallback.start()
        let client = GlassyStreamClient(credentialStore: RouteTestCredentialStore())
        defer { client.disconnect() }

        let authentication = try await authenticate(
            client,
            configuration: GlassyStreamConnectionConfiguration(
                endpoint: primaryEndpoint,
                savedMachineID: UUID(),
                bootstrapCredential: .oneTimeCode("ABCDEFGH2345"),
                expectedHostIdentifier: hostID,
                fallbackEndpoints: [fallbackEndpoint]
            )
        )
        // Let an already queued late primary hello run after selection.
        try await Task.sleep(for: .milliseconds(500))
        #expect(primary.proofCount == 0)
        #expect(fallback.proofCount == 1)
        #expect(authentication.hostIdentifier == hostID)
        #expect(!authentication.resumedSession)
        #expect(authentication.connectedAddress?.endpoint == fallbackEndpoint)
    }

    private func authenticate(
        _ client: GlassyStreamClient,
        configuration: GlassyStreamConnectionConfiguration
    ) async throws -> GlassyStreamAuthentication {
        try await withCheckedThrowingContinuation { continuation in
            let result = RouteTestResult(continuation)
            client.connect(
                configuration: configuration,
                callbackQueue: .global(),
                callbacks: GlassyStreamClientCallbacks(
                    onEvent: { event in
                        if case let .authenticated(authentication) = event {
                            result.finish(.success(authentication))
                        }
                    },
                    onCompletion: { completion in
                        switch completion {
                        case .success: result.finish(.failure(GlassyStreamClientError.connectionClosed))
                        case let .failure(error): result.finish(.failure(error))
                        }
                    }
                )
            )
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                if result.finish(.failure(GlassyStreamClientError.authenticationTimedOut)) {
                    client.disconnect()
                }
            }
        }
    }
}

private struct RouteTestCredentialStore: GlassyStreamResumeCredentialStoring {
    func credential(savedMachineID: UUID, hostIdentifier: Data) throws -> GlassyStreamResumeCredential? { nil }
    func save(_ credential: GlassyStreamResumeCredential, savedMachineID: UUID, hostIdentifier: Data) throws {}
    func removeCredential(savedMachineID: UUID, hostIdentifier: Data) throws {}
}

private final class RouteTestResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(with: result)
        return current != nil
    }
}

private final class LoopbackPairingHost: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.glassy.loopback-host")
    private let listener: NWListener
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private let hostID: Data
    private let behavior: String
    private var connections: [NWConnection] = []
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var receivedProofs = 0

    var proofCount: Int { queue.sync { receivedProofs } }

    init(hostID: Data, behavior: String) throws {
        self.hostID = hostID
        self.behavior = behavior
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> NWEndpoint {
        try await withCheckedThrowingContinuation { continuation in
            let result = RouteTestResult(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    result.finish(.success(.hostPort(host: "127.0.0.1", port: port)))
                case let .failed(error): result.finish(.failure(error))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                if result.finish(.failure(GlassyStreamClientError.authenticationTimedOut)) {
                    self?.listener.cancel()
                }
            }
        }
    }

    func stop() {
        queue.sync {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            for connection in connections {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
            connections.removeAll()
        }
    }

    private var hello: GlassyStreamWire.ServerHello {
        .init(hostIdentifier: hostID, serverNonce: Data(repeating: 0x31, count: 32),
              serverPublicKey: privateKey.publicKey.rawRepresentation, pairingWindow: 1,
              pairingCodeLifetimeSeconds: 60, capabilities: 7, serverName: "Fixture Mac")
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, case .ready = state else { return }
            if behavior == "late-hello" {
                queue.asyncAfter(deadline: .now() + 0.4) { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    sendHello(connection)
                }
            } else if behavior != "silent" {
                sendHello(connection)
            }
            receive(connection)
        }
        connection.start(queue: queue)
    }

    private func sendHello(_ connection: NWConnection) {
        do {
            var payload = hello.hostIdentifier
            payload.append(hello.serverNonce)
            payload.append(hello.serverPublicKey)
            append(hello.pairingWindow, to: &payload)
            append(hello.pairingCodeLifetimeSeconds, to: &payload)
            append(hello.capabilities, to: &payload)
            let name = Data(hello.serverName.utf8)
            append(UInt16(name.count), to: &payload)
            payload.append(name)
            let packet = try GlassyStreamWire.encode(.init(kind: .serverHello, flags: [], sequence: 1, payload: payload))
            connection.send(content: packet, completion: .contentProcessed { _ in })
        } catch { connection.cancel() }
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection else { return }
            let id = ObjectIdentifier(connection)
            var buffer = buffers[id] ?? Data()
            if let data { buffer.append(data) }
            do {
                while let frame = try GlassyStreamWire.decodeNextFrame(from: &buffer) {
                    if frame.kind == .clientHello {
                        receivedProofs += 1
                        try authenticate(frame, connection: connection)
                    }
                }
            } catch { connection.cancel(); return }
            buffers[id] = buffer
            if !complete, error == nil { receive(connection) }
        }
    }

    private func authenticate(_ frame: GlassyStreamWire.Frame, connection: NWConnection) throws {
        var reader = RouteTestReader(data: frame.payload)
        let clientID = try reader.read(16)
        let nonce = try reader.read(32)
        let publicKey = try reader.read(32)
        let methodByte = try reader.read(1).first!
        _ = try reader.read(3)
        let window = try reader.integer(8)
        let nameLength = try reader.integer(2)
        let name = String(decoding: try reader.read(Int(nameLength)), as: UTF8.self)
        let proof = try reader.read(32)
        guard let method = GlassyStreamWire.AuthenticationMethod(rawValue: methodByte),
              method == .pairingCode else { throw GlassyStreamClientError.invalidPairingCode }
        let clientHello = GlassyStreamWire.ClientHello(
            clientIdentifier: clientID, clientNonce: nonce, clientPublicKey: publicKey,
            authenticationMethod: method, pairingWindow: window, clientName: name, proof: proof
        )
        let shared = try privateKey.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        )
        let transcript = try GlassyStreamWire.authenticationTranscript(serverHello: hello, clientHello: clientHello)
        let credential = Data("ABCDEFGH2345".utf8)
        let key = GlassyStreamWire.authenticationKey(sharedSecret: shared, credential: credential, transcript: transcript)
        guard proof == GlassyStreamWire.authenticationProof(authenticationKey: key, transcript: transcript) else {
            throw GlassyStreamClientError.authenticationRejected("Invalid synthetic proof")
        }
        let material = GlassyStreamWire.sessionMaterial(sharedSecret: shared, credential: credential, transcript: transcript)
        var accepted = clientID
        accepted.append(Data(repeating: 0x61, count: 32))
        append(UInt64(1), to: &accepted)
        append(UInt32(16 * 1024 * 1024), to: &accepted)
        let ciphertext = try GlassyStreamWire.seal(
            accepted, kind: .authenticationAccepted, flags: [.encrypted], sequence: 2,
            material: material, serverToClient: true
        )
        let packet = try GlassyStreamWire.encode(
            .init(kind: .authenticationAccepted, flags: [.encrypted], sequence: 2, payload: ciphertext)
        )
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func append<Integer: FixedWidthInteger>(_ value: Integer, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}

private struct RouteTestReader {
    let data: Data
    var offset = 0

    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw GlassyStreamClientError.protocolViolation("Truncated synthetic ClientHello")
        }
        defer { offset += count }
        return Data(data[offset..<offset + count])
    }

    mutating func integer(_ count: Int) throws -> UInt64 {
        try read(count).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
