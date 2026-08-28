import CryptoKit
import Foundation
import Network
import OSLog
import Security

/// A Bonjour-advertised, authenticated Glassy Host server.
///
/// `HostServer` owns a dedicated serial network core. No video packet is ever
/// enqueued for a connection until that connection has completed the
/// challenge/proof handshake.
final class HostServer: @unchecked Sendable {
    enum Status: Equatable, Sendable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)

    }

    typealias ClientCountHandler = @Sendable (Int) -> Void
    typealias StatusHandler = @Sendable (Status) -> Void
    typealias RemoteInputHandler = @Sendable (HostProtocol.RemoteInputEvent) -> Void
    typealias StreamQualityHandler = @Sendable (HostProtocol.StreamQuality) -> Void
    typealias AuthenticatedClientReplacementHandler = @Sendable () -> Void

    struct PairingCode: Equatable, Sendable {
        let value: String
        let expiresAt: Date
    }

    private let core: Core
    private let pairingCodeSource = PairingCodeSource()

    init(serviceName: String = Host.current().localizedName ?? "Glassy Host") {
        core = Core(serviceName: serviceName)
    }

    deinit {
        core.stop()
    }

    /// Starts with a controller-owned 256-bit device-local credential. Repeating
    /// this call with the same secret is idempotent; a different secret safely
    /// replaces the listener and all sessions.
    func start(pairingSecret: Data,
               onClientCountChange: @escaping ClientCountHandler = { _ in },
               onStatusChange: @escaping StatusHandler = { _ in }) {
        guard pairingSecret.count >= 32 else {
            onStatusChange(.failed("The pairing secret must contain at least 32 random bytes."))
            return
        }
        pairingCodeSource.replaceSecret(pairingSecret)
        core.start(pairingSecret: pairingSecret,
                   onClientCountChange: onClientCountChange,
                   onStatusChange: onStatusChange)
    }

    func stop() {
        core.stop()
    }

    /// Rotates the root credential, invalidating all resume secrets, and starts
    /// a fresh listener while preserving the registered callbacks.
    func replacePairingSecretAndRestart(_ pairingSecret: Data) {
        guard pairingSecret.count >= 32 else {
            core.reportInvalidPairingSecret()
            return
        }
        pairingCodeSource.replaceSecret(pairingSecret)
        core.replacePairingSecretAndRestart(pairingSecret)
    }

    /// A thread-safe snapshot for UI. The root secret is never returned or
    /// displayed; this code is derived for one 60-second pairing window.
    func currentPairingCode(at date: Date = Date()) -> PairingCode? {
        pairingCodeSource.currentPairingCode(at: date)
    }

    /// Installs the callback the encoder should use to force an IDR frame when
    /// a newly authenticated viewer joins or the codec configuration changes.
    func setKeyFrameRequestHandler(_ handler: (@Sendable () -> Void)?) {
        core.setKeyFrameRequestHandler(handler)
    }

    /// Installs the sink for authenticated direct-input messages. The network
    /// core never invokes this callback before the encrypted handshake finishes.
    func setRemoteInputHandler(_ handler: RemoteInputHandler?) {
        core.setRemoteInputHandler(handler)
    }

    /// Installs a callback used to retire any input state owned by a stale
    /// transport before its authenticated replacement can submit new input.
    func setAuthenticatedClientReplacementHandler(
        _ handler: AuthenticatedClientReplacementHandler?
    ) {
        core.setAuthenticatedClientReplacementHandler(handler)
    }

    /// Installs the sink for the effective host-wide stream quality. One encoder
    /// serves every viewer, so the network core selects the most conservative
    /// request made by any authenticated client. With no clients, this is Best.
    func setStreamQualityHandler(_ handler: StreamQualityHandler?) {
        core.setStreamQualityHandler(handler)
    }

    /// Removes H.264 bootstrap data, cursor telemetry, and queued media from the
    /// capture generation that just ended. The controller calls this only after
    /// the encoder has completed its callbacks, so a late callback cannot
    /// restore stale state.
    func clearVideoState() async {
        await core.clearVideoState()
    }

    /// Broadcasts H.264 SPS/PPS configuration to authenticated clients and
    /// caches it for the next viewer.
    func broadcastCodecConfiguration(parameterSets: [Data],
                                     nalUnitHeaderLength: Int) {
        do {
            let payload = try HostProtocol.encodeVideoConfiguration(
                parameterSets: parameterSets,
                nalUnitHeaderLength: nalUnitHeaderLength
            )
            core.broadcastCodecConfiguration(payload)
        } catch {
            Core.logger.error("Rejected codec configuration: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Broadcasts one AVCC H.264 access unit. Delta frames use newest-only
    /// queueing; keyframes are retained or the slow client is disconnected.
    func broadcastVideoAccessUnit(_ avccData: Data,
                                  presentationTimeSeconds: Double,
                                  durationSeconds: Double?,
                                  isKeyFrame: Bool) {
        do {
            let payload = try HostProtocol.encodeVideoAccessUnit(
                avccData,
                presentationTimeSeconds: presentationTimeSeconds,
                durationSeconds: durationSeconds
            )
            core.broadcastVideoAccessUnit(payload, isKeyFrame: isKeyFrame)
        } catch {
            Core.logger.error("Rejected video access unit: \(error.localizedDescription, privacy: .public)")
        }
    }

    func broadcastKeyFrame(_ avccData: Data,
                           presentationTimeSeconds: Double,
                           durationSeconds: Double?) {
        broadcastVideoAccessUnit(avccData,
                                 presentationTimeSeconds: presentationTimeSeconds,
                                 durationSeconds: durationSeconds,
                                 isKeyFrame: true)
    }

    func broadcastDeltaFrame(_ avccData: Data,
                             presentationTimeSeconds: Double,
                             durationSeconds: Double?) {
        broadcastVideoAccessUnit(avccData,
                                 presentationTimeSeconds: presentationTimeSeconds,
                                 durationSeconds: durationSeconds,
                                 isKeyFrame: false)
    }

    /// Publishes the cursor location associated with the current capture frame.
    /// Only authenticated clients that explicitly opted in receive telemetry.
    func broadcastCursorPosition(_ position: HostProtocol.CursorPosition) {
        core.broadcastCursorPosition(position)
    }

    /// Invalidates telemetry when the cursor leaves the captured display.
    func clearCursorPosition() {
        core.clearCursorPosition()
    }

    fileprivate static func makeHostIdentifier(from pairingSecret: Data) -> Data {
        let digest = HMAC<SHA256>.authenticationCode(
            for: Data("Glassy Host identity v1".utf8),
            using: SymmetricKey(data: pairingSecret)
        )
        return Data(digest.prefix(HostProtocol.identifierLength))
    }
}

// MARK: - Network core

private extension HostServer {
    final class Core: @unchecked Sendable {
        static let logger = HostLog.network

        private static let maximumConnections = 12
        private static let maximumUnauthenticatedConnections = 4
        private static let authenticationTimeout: TimeInterval = 15
        private static let maximumPairingFailuresPerMinute = 8
        private static let maximumQueuedBytesPerClient = 24 * 1024 * 1024
        private static let maximumQueuedMessagesPerClient = 10

        private let queue = DispatchQueue(label: "dev.bunn.glassydesk.host.server",
                                          qos: .userInteractive)
        private let serviceName: String

        private var listener: NWListener?
        private var generation = UUID()
        private var clients: [UUID: Client] = [:]
        private var authenticatedClientRegistry = HostAuthenticatedClientRegistry()
        private var rootSecret = SymmetricKey(size: .bits256)
        private var rootSecretData: Data?
        private var hostIdentifier = Data(repeating: 0,
                                          count: HostProtocol.identifierLength)
        private var failedPairingAttempts: [Date] = []
        private var videoBootstrapCache = HostVideoBootstrapCache()
        private var latestCursorPosition: HostProtocol.CursorPosition?
        private let mediaIngress = MediaIngress()
        private var keyFrameRequestHandler: (@Sendable () -> Void)?
        private var remoteInputHandler: RemoteInputHandler?
        private var authenticatedClientReplacementHandler:
            AuthenticatedClientReplacementHandler?
        private var streamQualityHandler: StreamQualityHandler = { _ in }
        private var streamQualityArbitration = HostStreamQualityArbitration()
        private var lastPublishedClientCount = 0
        private var lastStatus: Status = .stopped
        private var clientCountHandler: ClientCountHandler = { _ in }
        private var statusHandler: StatusHandler = { _ in }

        init(serviceName: String) {
            self.serviceName = serviceName
        }

        func start(pairingSecret: Data,
                   onClientCountChange: @escaping ClientCountHandler,
                   onStatusChange: @escaping StatusHandler) {
            queue.async { [weak self] in
                guard let self else { return }
                clientCountHandler = onClientCountChange
                statusHandler = onStatusChange

                if rootSecretData == pairingSecret, listener != nil {
                    switch lastStatus {
                    case .starting, .listening:
                        onClientCountChange(lastPublishedClientCount)
                        onStatusChange(lastStatus)
                        return
                    case .stopped, .failed:
                        break
                    }
                }
                startLocked(pairingSecret: pairingSecret)
            }
        }

        func stop() {
            queue.async { [weak self] in
                self?.stopLocked(publishStopped: true)
            }
        }

        func setKeyFrameRequestHandler(_ handler: (@Sendable () -> Void)?) {
            queue.async { [weak self] in
                guard let self else { return }
                keyFrameRequestHandler = handler
                guard let handler,
                      authenticatedClients.contains(where: \.needsKeyFrame) else { return }
                for client in authenticatedClients where client.needsKeyFrame {
                    client.keyFrameRequestOutstanding = true
                }
                handler()
            }
        }

        func setRemoteInputHandler(_ handler: RemoteInputHandler?) {
            queue.async { [weak self] in
                self?.remoteInputHandler = handler
            }
        }

        func setAuthenticatedClientReplacementHandler(
            _ handler: AuthenticatedClientReplacementHandler?
        ) {
            queue.async { [weak self] in
                self?.authenticatedClientReplacementHandler = handler
            }
        }

        func setStreamQualityHandler(_ handler: StreamQualityHandler?) {
            queue.async { [weak self] in
                guard let self else { return }
                streamQualityHandler = handler ?? { _ in }
                guard handler != nil else { return }
                publishEffectiveStreamQualityIfNeeded(force: true)
            }
        }

        func clearVideoState() async {
            await withCheckedContinuation { continuation in
                queue.async { [weak self] in
                    self?.clearVideoStateLocked()
                    continuation.resume()
                }
            }
        }

        func replacePairingSecretAndRestart(_ pairingSecret: Data) {
            queue.async { [weak self] in
                self?.startLocked(pairingSecret: pairingSecret)
            }
        }

        func reportInvalidPairingSecret() {
            queue.async { [weak self] in
                self?.publishStatus(.failed("The pairing secret must contain at least 32 random bytes."))
            }
        }

        func broadcastCodecConfiguration(_ payload: Data) {
            queue.async { [weak self] in
                guard let self else { return }
                videoBootstrapCache.storeCodecConfiguration(payload)
                for client in authenticatedClients {
                    client.needsKeyFrame = true
                    _ = enqueueEncrypted(payload,
                                         kind: .videoConfiguration,
                                         flags: [],
                                         policy: .codecConfiguration,
                                         for: client)
                }
                requestKeyFrameIfNeeded(for: authenticatedClients)
            }
        }

        private func clearVideoStateLocked() {
            videoBootstrapCache.clear()
            latestCursorPosition = nil
            mediaIngress.reset()

            for client in authenticatedClients {
                client.removeQueuedVideoPackets()
                client.needsKeyFrame = true
                client.keyFrameRequestOutstanding = false
                sendNextPacket(for: client)
            }
        }

        func broadcastVideoAccessUnit(_ payload: Data, isKeyFrame: Bool) {
            let shouldScheduleDrain = mediaIngress.submit(
                VideoBroadcast(payload: payload, isKeyFrame: isKeyFrame)
            )
            guard shouldScheduleDrain else { return }
            queue.async { [weak self] in
                self?.drainMediaIngress()
            }
        }

        func broadcastCursorPosition(_ position: HostProtocol.CursorPosition) {
            queue.async { [weak self] in
                guard let self else { return }
                latestCursorPosition = position
                let payload = HostProtocol.encodeCursorPosition(position)
                for client in authenticatedClients
                    where client.isSubscribedToCursorPosition {
                    _ = enqueueEncrypted(
                        payload,
                        kind: .cursorPosition,
                        flags: [],
                        policy: .cursorPosition,
                        for: client
                    )
                }
            }
        }

        func clearCursorPosition() {
            queue.async { [weak self] in
                guard let self else { return }
                latestCursorPosition = nil
                for client in authenticatedClients {
                    client.removeQueuedCursorPositions()
                }
            }
        }

        private func drainMediaIngress() {
            while let drain = mediaIngress.takeNext() {
                if drain.requiresKeyFrame {
                    for client in authenticatedClients {
                        client.needsKeyFrame = true
                    }
                    requestKeyFrameIfNeeded(for: authenticatedClients)
                }

                guard let item = drain.item else { continue }
                let flags: HostProtocol.Flags = item.isKeyFrame ? [.keyFrame] : []
                let policy: SendPolicy = item.isKeyFrame ? .keyFrame : .deltaFrame
                for client in authenticatedClients {
                    if !item.isKeyFrame, client.needsKeyFrame {
                        requestKeyFrameIfNeeded(for: [client])
                        continue
                    }

                    let wasQueued = enqueueEncrypted(item.payload,
                                                     kind: .videoAccessUnit,
                                                     flags: flags,
                                                     policy: policy,
                                                     for: client)
                    if item.isKeyFrame, wasQueued {
                        client.needsKeyFrame = false
                        client.keyFrameRequestOutstanding = false
                    } else if !item.isKeyFrame, !wasQueued {
                        client.needsKeyFrame = true
                        requestKeyFrameIfNeeded(for: [client])
                    }
                }
            }
        }

        private func requestKeyFrameIfNeeded(for clients: [Client]) {
            var shouldRequest = false
            for client in clients where client.needsKeyFrame
                && !client.keyFrameRequestOutstanding {
                client.keyFrameRequestOutstanding = true
                shouldRequest = true
            }
            if shouldRequest {
                keyFrameRequestHandler?()
            }
        }

        private var authenticatedClients: [Client] {
            clients.values.filter { client in
                guard client.isAuthenticated,
                      let clientIdentifier = client.clientIdentifier else {
                    return false
                }
                return authenticatedClientRegistry.isActive(
                    clientIdentifier: clientIdentifier,
                    connectionIdentifier: client.id
                )
            }
        }

        private func startLocked(pairingSecret: Data) {
            stopLocked(publishStopped: false)

            generation = UUID()
            let activeGeneration = generation
            rootSecretData = pairingSecret
            rootSecret = SymmetricKey(data: pairingSecret)
            hostIdentifier = HostServer.makeHostIdentifier(from: pairingSecret)
            failedPairingAttempts.removeAll(keepingCapacity: true)
            publishStatus(.starting)

            do {
                let tcpOptions = NWProtocolTCP.Options()
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveIdle = 10
                tcpOptions.keepaliveInterval = 5
                tcpOptions.keepaliveCount = 3
                let parameters = NWParameters(tls: nil, tcp: tcpOptions)
                parameters.allowLocalEndpointReuse = true
                parameters.includePeerToPeer = true

                let listener = try NWListener(using: parameters)
                listener.service = NWListener.Service(name: serviceName,
                                                      type: HostProtocol.bonjourServiceType)
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener,
                          activeGeneration == generation,
                          listener === self.listener else { return }
                    handleListenerState(state, listener: listener)
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, activeGeneration == generation else {
                        connection.cancel()
                        return
                    }
                    accept(connection)
                }
                self.listener = listener
                listener.start(queue: queue)
            } catch {
                publishStatus(.failed(error.localizedDescription))
            }
        }

        private func stopLocked(publishStopped: Bool) {
            generation = UUID()
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil

            let existingClients = Array(clients.values)
            clients.removeAll(keepingCapacity: true)
            authenticatedClientRegistry.removeAll()
            for client in existingClients {
                client.authenticationTimeout?.cancel()
                client.connection.stateUpdateHandler = nil
                client.connection.cancel()
                client.isClosed = true
            }
            publishAuthenticatedClientCountIfNeeded(force: true)
            publishEffectiveStreamQualityIfNeeded()
            if publishStopped {
                publishStatus(.stopped)
            }
        }

        private func handleListenerState(_ state: NWListener.State,
                                         listener: NWListener) {
            switch state {
            case .setup, .waiting:
                publishStatus(.starting)
            case .ready:
                guard let port = listener.port?.rawValue else {
                    publishStatus(.failed("The listener did not receive a TCP port."))
                    return
                }
                Self.logger.info("Glassy Host listening on port \(port, privacy: .public)")
                publishStatus(.listening(port: port))
            case let .failed(error):
                Self.logger.error("Listener failed: \(error.localizedDescription, privacy: .public)")
                if listener === self.listener {
                    self.listener = nil
                }
                publishStatus(.failed(error.localizedDescription))
            case .cancelled:
                break
            @unknown default:
                publishStatus(.failed("Unknown listener state."))
            }
        }

        private func publishStatus(_ status: Status) {
            lastStatus = status
            statusHandler(status)
        }

        private func accept(_ connection: NWConnection) {
            let unauthenticatedCount = clients.values.filter { !$0.isAuthenticated }.count
            guard clients.count < Self.maximumConnections,
                  unauthenticatedCount < Self.maximumUnauthenticatedConnections else {
                Self.logger.warning("Rejected connection because the client limit was reached")
                connection.cancel()
                return
            }

            let client = Client(connection: connection)
            clients[client.id] = client
            connection.stateUpdateHandler = { [weak self, weak client] state in
                guard let self, let client else { return }
                switch state {
                case .ready:
                    beginHandshake(with: client)
                case let .failed(error):
                    Self.logger.debug("Client connection failed: \(error.localizedDescription, privacy: .public)")
                    remove(client)
                case let .waiting(error):
                    // Authenticated viewers have their own bounded reconnect
                    // policy. Retiring a transport that can no longer make
                    // progress avoids keeping suspended iOS sessions in the
                    // host's active-client and capture-demand accounting.
                    if client.isAuthenticated {
                        Self.logger.debug("Authenticated viewer connection waiting: \(error.localizedDescription, privacy: .public)")
                        remove(client)
                    }
                case .cancelled:
                    remove(client)
                default:
                    break
                }
            }
            connection.start(queue: queue)

            let timeout = DispatchWorkItem { [weak self, weak client] in
                guard let self, let client, !client.isAuthenticated else { return }
                Self.logger.notice("Closed a client that did not authenticate in time")
                remove(client)
            }
            client.authenticationTimeout = timeout
            queue.asyncAfter(deadline: .now() + Self.authenticationTimeout,
                             execute: timeout)
        }

        private func beginHandshake(with client: Client) {
            guard case .connecting = client.authorizationState else { return }

            do {
                let privateKey = Curve25519.KeyAgreement.PrivateKey()
                let serverNonce = try secureRandomData(count: HostProtocol.nonceLength)
                let window = HostProtocol.pairingWindow(at: Date())
                let hello = HostProtocol.ServerHello(
                    hostIdentifier: hostIdentifier,
                    serverNonce: serverNonce,
                    serverPublicKey: privateKey.publicKey.rawRepresentation,
                    pairingWindow: window,
                    pairingCodeLifetimeSeconds: UInt16(HostProtocol.pairingCodeLifetime),
                    capabilities: HostProtocol.advertisedCapabilities.rawValue,
                    serverName: serviceName
                )
                client.authorizationState = .awaitingProof(
                    HandshakeContext(privateKey: privateKey, hello: hello)
                )
                let payload = try HostProtocol.encodeServerHello(hello)
                try enqueuePlaintext(payload,
                                     kind: .serverHello,
                                     flags: [],
                                     policy: .control,
                                     for: client)
                receiveNext(on: client)
            } catch {
                Self.logger.error("Could not begin handshake: \(error.localizedDescription, privacy: .public)")
                remove(client)
            }
        }

        private func receiveNext(on client: Client) {
            guard !client.isClosed else { return }
            client.connection.receive(minimumIncompleteLength: 1,
                                      maximumLength: 64 * 1024) { [weak self, weak client] data, _, isComplete, error in
                guard let self, let client, !client.isClosed else { return }

                if let data, !data.isEmpty {
                    client.receiveBuffer.append(data)
                    do {
                        try processReceiveBuffer(for: client)
                    } catch {
                        Self.logger.notice("Rejected client packet: \(error.localizedDescription, privacy: .public)")
                        if client.isAuthenticated {
                            // Never send a plaintext packet after the encrypted
                            // session begins. Closing is the least informative
                            // response to an integrity/protocol violation.
                            remove(client)
                        } else {
                            sendErrorAndClose(code: 1,
                                              message: "Invalid protocol message.",
                                              client: client)
                        }
                        return
                    }
                }

                if isComplete || error != nil {
                    remove(client)
                    return
                }

                if client.receiveBuffer.count > HostProtocol.maximumPayloadLength + HostProtocol.headerLength {
                    remove(client)
                    return
                }
                receiveNext(on: client)
            }
        }

        private func processReceiveBuffer(for client: Client) throws {
            while true {
                let payloadLimit = client.isAuthenticated
                    ? HostProtocol.maximumPayloadLength
                    : HostProtocol.maximumHandshakePayloadLength
                guard let frame = try HostProtocol.decodeNextFrame(
                    from: &client.receiveBuffer,
                    maximumPayloadLength: payloadLimit
                ) else { return }

                guard frame.sequence > client.lastInboundSequence else {
                    throw HostProtocol.ProtocolError.malformedPayload("replayed sequence")
                }
                client.lastInboundSequence = frame.sequence

                switch client.authorizationState {
                case .connecting:
                    throw HostProtocol.ProtocolError.malformedPayload("handshake not ready")
                case let .awaitingProof(context):
                    try authenticate(frame: frame, context: context, client: client)
                case let .authenticated(material):
                    try processAuthenticated(frame: frame,
                                             material: material,
                                             client: client)
                }
            }
        }

        private func authenticate(frame: HostProtocol.Frame,
                                  context: HandshakeContext,
                                  client: Client) throws {
            guard frame.sequence == 1,
                  frame.kind == .clientHello,
                  frame.flags.isEmpty,
                  frame.payload.count <= HostProtocol.maximumHandshakePayloadLength,
                  pairingAttemptIsAllowed() else {
                recordFailedPairingAttempt()
                throw HostProtocol.ProtocolError.invalidAuthentication
            }

            let hello = try HostProtocol.decodeClientHello(frame.payload)
            let publicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: hello.clientPublicKey
            )
            let sharedSecret = try context.privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            let transcript = try HostProtocol.authenticationTranscript(
                serverHello: context.hello,
                clientHello: hello
            )

            let resumeSecret = try HostProtocol.resumeSecret(
                rootSecret: rootSecret,
                clientIdentifier: hello.clientIdentifier
            )
            let credential: Data
            switch hello.authenticationMethod {
            case .pairingCode:
                let currentWindow = HostProtocol.pairingWindow(at: Date())
                let lowerWindow = min(hello.pairingWindow, currentWindow)
                let upperWindow = max(hello.pairingWindow, currentWindow)
                guard upperWindow - lowerWindow <= 1 else {
                    recordFailedPairingAttempt()
                    throw HostProtocol.ProtocolError.invalidAuthentication
                }
                let code = HostProtocol.pairingCode(rootSecret: rootSecret,
                                                    window: hello.pairingWindow)
                credential = Data(code.utf8)
            case .resumeSecret:
                credential = resumeSecret
            }

            let authenticationKey = HostProtocol.authenticationKey(
                sharedSecret: sharedSecret,
                credential: credential,
                transcript: transcript
            )
            guard HostProtocol.isValidProof(hello.proof,
                                            authenticationKey: authenticationKey,
                                            transcript: transcript) else {
                recordFailedPairingAttempt()
                throw HostProtocol.ProtocolError.invalidAuthentication
            }

            let material = HostProtocol.sessionMaterial(sharedSecret: sharedSecret,
                                                        credential: credential,
                                                        transcript: transcript)
            client.authorizationState = .authenticated(material)
            client.clientIdentifier = hello.clientIdentifier
            client.needsKeyFrame = true
            client.authenticationTimeout?.cancel()
            client.authenticationTimeout = nil

            if let replacedConnectionIdentifier = authenticatedClientRegistry.activate(
                clientIdentifier: hello.clientIdentifier,
                connectionIdentifier: client.id
            ), replacedConnectionIdentifier != client.id,
               let replacedClient = clients[replacedConnectionIdentifier] {
                Self.logger.info("Replacing a stale authenticated Glassy viewer connection")
                authenticatedClientReplacementHandler?()
                remove(replacedClient, publishChanges: false)
            }

            let accepted = HostProtocol.AuthenticationAccepted(
                clientIdentifier: hello.clientIdentifier,
                resumeSecret: resumeSecret,
                serverTimeMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000),
                maximumMediaPayloadLength: UInt32(HostProtocol.maximumPayloadLength)
            )
            let acceptedPayload = try HostProtocol.encodeAuthenticationAccepted(accepted)
            _ = enqueueEncrypted(acceptedPayload,
                                 kind: .authenticationAccepted,
                                 flags: [],
                                 policy: .control,
                                 for: client)

            if let cachedCodecConfiguration = videoBootstrapCache.codecConfiguration {
                _ = enqueueEncrypted(cachedCodecConfiguration,
                                     kind: .videoConfiguration,
                                     flags: [],
                                     policy: .codecConfiguration,
                                     for: client)
            }

            Self.logger.info("Authenticated a Glassy viewer")
            publishAuthenticatedClientCountIfNeeded()
            publishEffectiveStreamQualityIfNeeded()
            requestKeyFrameIfNeeded(for: [client])
        }

        private func processAuthenticated(frame: HostProtocol.Frame,
                                          material: HostProtocol.SessionMaterial,
                                          client: Client) throws {
            guard frame.flags.contains(.encrypted),
                  !frame.flags.contains(.keyFrame) else {
                throw HostProtocol.ProtocolError.invalidCiphertext
            }

            let plaintext = try HostProtocol.open(frame.payload,
                                                  kind: frame.kind,
                                                  flags: frame.flags,
                                                  sequence: frame.sequence,
                                                  material: material,
                                                  serverToClient: false)
            switch frame.kind {
            case .ping:
                guard plaintext.count <= 64 else {
                    throw HostProtocol.ProtocolError.payloadTooLarge(plaintext.count)
                }
                _ = enqueueEncrypted(plaintext,
                                     kind: .pong,
                                     flags: [],
                                     policy: .control,
                                     for: client)
            case .keyFrameRequest:
                try HostProtocol.decodeKeyFrameRequest(plaintext)
                client.needsKeyFrame = true
                requestKeyFrameIfNeeded(for: [client])
            case .streamQualityRequest:
                let requestedQuality = try HostProtocol.decodeStreamQualityRequest(plaintext)
                guard requestedQuality != client.requestedQuality else { return }
                client.requestedQuality = requestedQuality
                publishEffectiveStreamQualityIfNeeded()
            case .cursorPositionSubscriptionRequest:
                try HostProtocol.decodeCursorPositionSubscriptionRequest(plaintext)
                guard !client.isSubscribedToCursorPosition else { return }
                client.isSubscribedToCursorPosition = true
                if let latestCursorPosition {
                    _ = enqueueEncrypted(
                        HostProtocol.encodeCursorPosition(latestCursorPosition),
                        kind: .cursorPosition,
                        flags: [],
                        policy: .cursorPosition,
                        for: client
                    )
                }
            case .pointerInput, .scrollInput, .keyInput, .textInput:
                let input = try HostProtocol.decodeRemoteInput(
                    kind: frame.kind,
                    payload: plaintext
                )
                remoteInputHandler?(input)
            default:
                throw HostProtocol.ProtocolError.malformedPayload(
                    "message is not valid in the authenticated client direction"
                )
            }
        }

        private func enqueuePlaintext(_ payload: Data,
                                      kind: HostProtocol.MessageKind,
                                      flags: HostProtocol.Flags,
                                      policy: SendPolicy,
                                      for client: Client) throws {
            let sequence = client.takeNextOutboundSequence()
            let frame = HostProtocol.Frame(kind: kind,
                                           flags: flags,
                                           sequence: sequence,
                                           payload: payload)
            _ = try enqueuePacket(HostProtocol.encode(frame), policy: policy, for: client)
        }

        private func enqueueEncrypted(_ plaintext: Data,
                                      kind: HostProtocol.MessageKind,
                                      flags: HostProtocol.Flags,
                                      policy: SendPolicy,
                                      for client: Client) -> Bool {
            guard case let .authenticated(material) = client.authorizationState else {
                return false
            }

            do {
                let sequence = client.takeNextOutboundSequence()
                let encryptedFlags = flags.union(.encrypted)
                let payload = try HostProtocol.seal(plaintext,
                                                    kind: kind,
                                                    flags: flags,
                                                    sequence: sequence,
                                                    material: material,
                                                    serverToClient: true)
                let frame = HostProtocol.Frame(kind: kind,
                                               flags: encryptedFlags,
                                               sequence: sequence,
                                               payload: payload)
                return try enqueuePacket(HostProtocol.encode(frame),
                                         policy: policy,
                                         for: client)
            } catch {
                Self.logger.error("Could not queue encrypted packet: \(error.localizedDescription, privacy: .public)")
                if policy != .deltaFrame, policy != .cursorPosition {
                    remove(client)
                }
                return false
            }
        }

        private func enqueuePacket(_ packet: Data,
                                   policy: SendPolicy,
                                   for client: Client) throws -> Bool {
            guard !client.isClosed else { return false }

            if policy == .cursorPosition {
                client.removeQueuedCursorPositions()
                let exceedsByteLimit = client.totalQueuedBytes + packet.count
                    > Self.maximumQueuedBytesPerClient
                let exceedsMessageLimit = client.totalQueuedMessageCount + 1
                    > Self.maximumQueuedMessagesPerClient
                guard !exceedsByteLimit, !exceedsMessageLimit else {
                    // Telemetry is opportunistic and must never displace video
                    // or control traffic on a slow viewer.
                    return false
                }
            } else if client.totalQueuedBytes + packet.count > Self.maximumQueuedBytesPerClient
                || client.totalQueuedMessageCount + 1 > Self.maximumQueuedMessagesPerClient {
                if client.removeQueuedDeltaFrames() {
                    client.needsKeyFrame = true
                    if policy != .keyFrame {
                        requestKeyFrameIfNeeded(for: [client])
                    }
                }
            }

            guard client.totalQueuedBytes + packet.count <= Self.maximumQueuedBytesPerClient,
                  client.totalQueuedMessageCount + 1 <= Self.maximumQueuedMessagesPerClient else {
                if policy == .deltaFrame {
                    client.needsKeyFrame = true
                    requestKeyFrameIfNeeded(for: [client])
                    return false
                }
                if policy == .cursorPosition {
                    return false
                }
                throw HostProtocol.ProtocolError.payloadTooLarge(packet.count)
            }

            // If backpressure discarded a reference frame, no later delta is
            // independently decodable. Wait for IDR instead of showing damage.
            if policy == .deltaFrame, client.needsKeyFrame {
                requestKeyFrameIfNeeded(for: [client])
                return false
            }

            client.pendingPackets.append(PendingPacket(data: packet, policy: policy))
            client.pendingByteCount += packet.count
            sendNextPacket(for: client)
            return true
        }

        private func sendNextPacket(for client: Client) {
            guard !client.isClosed,
                  client.inFlightByteCount == 0,
                  !client.pendingPackets.isEmpty else { return }

            let pending = client.pendingPackets.removeFirst()
            client.pendingByteCount -= pending.data.count
            client.inFlightByteCount = pending.data.count
            client.connection.send(content: pending.data,
                                   completion: .contentProcessed { [weak self, weak client] error in
                guard let self, let client, !client.isClosed else { return }
                client.inFlightByteCount = 0
                if let error {
                    Self.logger.debug("Client send failed: \(error.localizedDescription, privacy: .public)")
                    remove(client)
                } else {
                    sendNextPacket(for: client)
                }
            })
        }

        private func sendErrorAndClose(code: UInt16,
                                       message: String,
                                       client: Client) {
            guard !client.isClosed else { return }
            let payload = (try? HostProtocol.encodeError(code: code, message: message)) ?? Data()
            let sequence = client.takeNextOutboundSequence()
            let frame = HostProtocol.Frame(kind: .protocolError,
                                           flags: [],
                                           sequence: sequence,
                                           payload: payload)
            let packet = try? HostProtocol.encode(frame)
            client.isClosed = true
            client.authenticationTimeout?.cancel()
            if let packet {
                client.connection.send(content: packet,
                                       completion: .contentProcessed { [weak self, weak client] _ in
                    client?.connection.cancel()
                    if let client { self?.remove(client) }
                })
            } else {
                client.connection.cancel()
                remove(client)
            }
        }

        private func remove(_ client: Client, publishChanges: Bool = true) {
            guard clients.removeValue(forKey: client.id) != nil else { return }
            if let clientIdentifier = client.clientIdentifier {
                // A resumed session may already own this stable identity. Only
                // the connection currently registered for it can clear it.
                _ = authenticatedClientRegistry.deactivate(
                    clientIdentifier: clientIdentifier,
                    connectionIdentifier: client.id
                )
            }
            client.isClosed = true
            client.authenticationTimeout?.cancel()
            client.connection.stateUpdateHandler = nil
            client.connection.cancel()
            guard publishChanges else { return }
            publishAuthenticatedClientCountIfNeeded()
            publishEffectiveStreamQualityIfNeeded()
        }

        private func pairingAttemptIsAllowed(at date: Date = Date()) -> Bool {
            failedPairingAttempts.removeAll {
                date.timeIntervalSince($0) >= 60
            }
            return failedPairingAttempts.count < Self.maximumPairingFailuresPerMinute
        }

        private func recordFailedPairingAttempt() {
            failedPairingAttempts.append(Date())
        }

        private func publishAuthenticatedClientCountIfNeeded(force: Bool = false) {
            let count = authenticatedClientRegistry.activeConnectionCount
            guard force || count != lastPublishedClientCount else { return }
            lastPublishedClientCount = count
            clientCountHandler(count)
        }

        private func publishEffectiveStreamQualityIfNeeded(force: Bool = false) {
            let requestedQualities = authenticatedClients.lazy.map(\.requestedQuality)
            guard let quality = streamQualityArbitration.qualityToPublish(
                for: requestedQualities,
                force: force
            ) else { return }
            streamQualityHandler(quality)
        }

        private func secureRandomData(count: Int) throws -> Data {
            var data = Data(count: count)
            let status = data.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let baseAddress = bytes.baseAddress else { return errSecParam }
                return SecRandomCopyBytes(kSecRandomDefault, bytes.count, baseAddress)
            }
            guard status == errSecSuccess else {
                throw HostProtocol.ProtocolError.malformedPayload(
                    "secure random generation failed (\(status))"
                )
            }
            return data
        }
    }
}

private extension HostServer.Core {
    struct HandshakeContext: @unchecked Sendable {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let hello: HostProtocol.ServerHello
    }

    enum AuthorizationState: @unchecked Sendable {
        case connecting
        case awaitingProof(HandshakeContext)
        case authenticated(HostProtocol.SessionMaterial)
    }

    enum SendPolicy: Equatable, Sendable {
        case control
        case codecConfiguration
        case keyFrame
        case deltaFrame
        case cursorPosition
    }

    struct PendingPacket: Sendable {
        let data: Data
        let policy: SendPolicy
    }

    struct VideoBroadcast: Sendable {
        let payload: Data
        let isKeyFrame: Bool
    }

    /// A one-item, lock-protected ingress buffer. This bounds work *before* the
    /// serial network queue as well as each client's Network.framework queue.
    final class MediaIngress: @unchecked Sendable {
        struct Drain: Sendable {
            let item: VideoBroadcast?
            let requiresKeyFrame: Bool
        }

        private let lock = NSLock()
        private var pending: VideoBroadcast?
        private var drainIsScheduled = false
        private var awaitingKeyFrame = false
        private var keyFrameRequestWasReported = false

        /// Returns true exactly when the caller must schedule a drain.
        func submit(_ item: VideoBroadcast) -> Bool {
            lock.withLock {
                if item.isKeyFrame {
                    // An IDR repairs any dependency chain broken by an ingress
                    // drop, so it supersedes whatever has not reached Core.
                    pending = item
                    awaitingKeyFrame = false
                    keyFrameRequestWasReported = false
                } else if awaitingKeyFrame {
                    // Once a P-frame is dropped, later P-frames are not safe to
                    // decode even when they are newer.
                } else if pending == nil {
                    pending = item
                } else {
                    // Keep the already-pending frame, drop this one, then wait
                    // for IDR because a later encoded frame may reference it.
                    awaitingKeyFrame = true
                }

                let hasWork = pending != nil
                    || (awaitingKeyFrame && !keyFrameRequestWasReported)
                guard hasWork, !drainIsScheduled else { return false }
                drainIsScheduled = true
                return true
            }
        }

        func takeNext() -> Drain? {
            lock.withLock {
                let shouldRequestKeyFrame = awaitingKeyFrame
                    && !keyFrameRequestWasReported
                if shouldRequestKeyFrame {
                    keyFrameRequestWasReported = true
                }

                if let pending {
                    self.pending = nil
                    return Drain(item: pending,
                                 requiresKeyFrame: shouldRequestKeyFrame)
                }
                if shouldRequestKeyFrame {
                    return Drain(item: nil, requiresKeyFrame: true)
                }

                drainIsScheduled = false
                return nil
            }
        }

        func reset() {
            lock.withLock {
                pending = nil
                drainIsScheduled = false
                awaitingKeyFrame = false
                keyFrameRequestWasReported = false
            }
        }
    }

    final class Client: @unchecked Sendable {
        let id = UUID()
        let connection: NWConnection
        var authorizationState: AuthorizationState = .connecting
        var clientIdentifier: Data?
        var receiveBuffer = Data()
        var lastInboundSequence: UInt64 = 0
        var nextOutboundSequence: UInt64 = 1
        var pendingPackets: [PendingPacket] = []
        var pendingByteCount = 0
        var inFlightByteCount = 0
        var authenticationTimeout: DispatchWorkItem?
        var isClosed = false
        var needsKeyFrame = true
        var keyFrameRequestOutstanding = false
        // A client that never sends the optional request retains legacy quality.
        var requestedQuality: HostProtocol.StreamQuality = .best
        // Cursor telemetry is opt-in so older clients receive no new messages.
        var isSubscribedToCursorPosition = false

        init(connection: NWConnection) {
            self.connection = connection
        }

        var isAuthenticated: Bool {
            if case .authenticated = authorizationState { return true }
            return false
        }

        var totalQueuedBytes: Int {
            pendingByteCount + inFlightByteCount
        }

        var totalQueuedMessageCount: Int {
            pendingPackets.count + (inFlightByteCount == 0 ? 0 : 1)
        }

        func takeNextOutboundSequence() -> UInt64 {
            defer { nextOutboundSequence &+= 1 }
            return nextOutboundSequence
        }

        @discardableResult
        func removeQueuedDeltaFrames() -> Bool {
            var removedAny = false
            pendingPackets.removeAll { packet in
                guard packet.policy == .deltaFrame else { return false }
                pendingByteCount -= packet.data.count
                removedAny = true
                return true
            }
            return removedAny
        }
        func removeQueuedVideoPackets() {
            pendingPackets.removeAll { packet in
                switch packet.policy {
                case .codecConfiguration, .keyFrame, .deltaFrame, .cursorPosition:
                    pendingByteCount -= packet.data.count
                    return true
                case .control:
                    return false
                }
            }
        }

        func removeQueuedCursorPositions() {
            pendingPackets.removeAll { packet in
                guard packet.policy == .cursorPosition else { return false }
                pendingByteCount -= packet.data.count
                return true
            }
        }
    }
}

/// Maintains the one active authenticated connection for each stable viewer
/// identity. Re-registration is a single dictionary update, and removal is
/// identity-checked so a delayed callback from a replaced connection cannot
/// evict its successor.
struct HostAuthenticatedClientRegistry: Sendable {
    private var connectionByClientIdentifier: [Data: UUID] = [:]

    var activeConnectionCount: Int {
        connectionByClientIdentifier.count
    }

    @discardableResult
    mutating func activate(clientIdentifier: Data,
                           connectionIdentifier: UUID) -> UUID? {
        connectionByClientIdentifier.updateValue(
            connectionIdentifier,
            forKey: clientIdentifier
        )
    }

    @discardableResult
    mutating func deactivate(clientIdentifier: Data,
                             connectionIdentifier: UUID) -> Bool {
        guard connectionByClientIdentifier[clientIdentifier]
            == connectionIdentifier else {
            return false
        }
        connectionByClientIdentifier.removeValue(forKey: clientIdentifier)
        return true
    }

    func isActive(clientIdentifier: Data,
                  connectionIdentifier: UUID) -> Bool {
        connectionByClientIdentifier[clientIdentifier] == connectionIdentifier
    }

    mutating func removeAll() {
        connectionByClientIdentifier.removeAll(keepingCapacity: true)
    }
}

struct HostVideoBootstrapCache: Sendable {
    private(set) var codecConfiguration: Data?

    mutating func storeCodecConfiguration(_ payload: Data) {
        codecConfiguration = payload
    }

    mutating func clear() {
        codecConfiguration = nil
    }
}

struct HostStreamQualityArbitration: Sendable {
    private(set) var lastPublishedQuality: HostProtocol.StreamQuality = .best

    static func effectiveQuality<S: Sequence>(
        for requestedQualities: S
    ) -> HostProtocol.StreamQuality where S.Element == HostProtocol.StreamQuality {
        requestedQualities.min { lhs, rhs in
            lhs.rawValue < rhs.rawValue
        } ?? .best
    }

    mutating func qualityToPublish<S: Sequence>(
        for requestedQualities: S,
        force: Bool = false
    ) -> HostProtocol.StreamQuality? where S.Element == HostProtocol.StreamQuality {
        let quality = Self.effectiveQuality(for: requestedQualities)
        guard force || quality != lastPublishedQuality else { return nil }
        lastPublishedQuality = quality
        return quality
    }
}

private final class PairingCodeSource: @unchecked Sendable {
    private let lock = NSLock()
    private var rootSecret: SymmetricKey?

    func replaceSecret(_ data: Data) {
        lock.withLock {
            rootSecret = SymmetricKey(data: data)
        }
    }

    func currentPairingCode(at date: Date) -> HostServer.PairingCode? {
        lock.withLock {
            guard let rootSecret else { return nil }
            let window = HostProtocol.pairingWindow(at: date)
            let value = HostProtocol.pairingCode(rootSecret: rootSecret, window: window)
            let expiry = Date(
                timeIntervalSince1970: TimeInterval(window + 1) * HostProtocol.pairingCodeLifetime
            )
            return HostServer.PairingCode(value: value, expiresAt: expiry)
        }
    }
}
