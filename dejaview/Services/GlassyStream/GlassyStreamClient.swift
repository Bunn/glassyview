import CryptoKit
import Foundation
import Network
import Security

/// An encrypted Glassy Host transport selected from bounded concurrent routes.
///
/// `connect` is callback-first so media can move directly from the Network
/// queue to a renderer queue without MainActor work. `eventStream` is provided
/// for consumers that continuously drain an async sequence.
final class GlassyStreamClient: @unchecked Sendable {
    private struct PendingAuthentication: Sendable {
        let material: GlassyStreamWire.SessionMaterial
        let hostIdentifier: Data
        let hostName: String
        let clientIdentifier: Data
        let resumedSession: Bool
        let supportsStreamQuality: Bool
        let supportsCursorPositionUpdates: Bool
    }

    private enum State: Sendable {
        case idle
        case connecting
        case awaitingServerHello
        case awaitingAuthentication(PendingAuthentication)
        case authenticated(GlassyStreamWire.SessionMaterial)
    }

    private let queue = DispatchQueue(label: "dev.bunn.glassydesk.glassy-stream.network",
                                      qos: .userInteractive)
    private let credentialStore: any GlassyStreamResumeCredentialStoring

    private var generation = UUID()
    private var connection: NWConnection?
    private var routeRace: GlassyStreamRouteRace?
    private var selectedEndpoint: NWEndpoint?
    private var state: State = .idle
    private var configuration: GlassyStreamConnectionConfiguration?
    private var callbackQueue: DispatchQueue?
    private var callbacks: GlassyStreamClientCallbacks?
    private var receiveBuffer = Data()
    private var lastInboundSequence: UInt64 = 0
    private var nextOutboundSequence: UInt64 = 1
    private var maximumInboundPayloadLength = GlassyStreamWire.maximumHandshakePayloadLength
    private var authenticationTimeoutWorkItem: DispatchWorkItem?
    private var supportsStreamQuality = false
    private var supportsCursorPositionUpdates = false

    init(credentialStore: any GlassyStreamResumeCredentialStoring = GlassyStreamKeychainCredentialStore()) {
        self.credentialStore = credentialStore
    }

    deinit {
        authenticationTimeoutWorkItem?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.viabilityUpdateHandler = nil
        connection?.cancel()
    }

    /// Starts resolving/connecting to either a Bonjour `.service` endpoint or
    /// a direct host/port endpoint. Callbacks are always delivered in order on
    /// `callbackQueue`.
    func connect(configuration: GlassyStreamConnectionConfiguration,
                 callbackQueue: DispatchQueue = .main,
                 callbacks: GlassyStreamClientCallbacks) {
        queue.async { [weak self] in
            self?.start(configuration: configuration,
                        callbackQueue: callbackQueue,
                        callbacks: callbacks)
        }
    }

    /// Async-sequence convenience. This stream is intentionally unbounded:
    /// the media renderer must drain it continuously so decoder configuration
    /// can never be discarded ahead of the keyframe that depends on it. The
    /// callback API is preferred when the consumer has its own bounded queue.
    func eventStream(configuration: GlassyStreamConnectionConfiguration,
                     callbackQueue: DispatchQueue = .main)
        -> AsyncThrowingStream<GlassyStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            connect(
                configuration: configuration,
                callbackQueue: callbackQueue,
                callbacks: GlassyStreamClientCallbacks(
                    onEvent: { event in
                        continuation.yield(event)
                    },
                    onCompletion: { result in
                        switch result {
                        case .success:
                            continuation.finish()
                        case let .failure(error):
                            continuation.finish(throwing: error)
                        }
                    }
                )
            )
            continuation.onTermination = { [weak self] _ in
                self?.disconnect()
            }
        }
    }

    /// Ends the active connection. A caller-requested disconnect completes
    /// successfully; remote/network/protocol failures complete with an error.
    func disconnect() {
        queue.async { [weak self] in
            guard let self, callbacks != nil else { return }
            finish(.success(()), generation: generation)
        }
    }

    func sendPing(_ payload: Data = Data()) {
        queue.async { [weak self] in
            guard let self,
                  payload.count <= 64,
                  case let .authenticated(material) = state else { return }
            do {
                try sendEncrypted(payload,
                                  kind: .ping,
                                  flags: [],
                                  material: material,
                                  generation: generation)
            } catch {
                finish(.failure(clientError(error)), generation: generation)
            }
        }
    }

    func requestKeyFrame() {
        sendAuthenticated(kind: .keyFrameRequest) {
            GlassyStreamWire.encodeKeyFrameRequest()
        }
    }

    func setStreamQuality(_ quality: RemoteSessionQuality) {
        queue.async { [weak self] in
            guard let self,
                  supportsStreamQuality,
                  case let .authenticated(material) = state,
                  connection != nil else {
                return
            }

            do {
                try sendEncrypted(
                    GlassyStreamWire.encodeStreamQualityRequest(quality),
                    kind: .streamQualityRequest,
                    flags: [],
                    material: material,
                    generation: generation
                )
            } catch {
                finish(.failure(clientError(error)), generation: generation)
            }
        }
    }

    func sendPointerInput(
        x: UInt16,
        y: UInt16,
        buttons: GlassyStreamPointerButtons
    ) {
        sendAuthenticated(kind: .pointerInput) {
            try GlassyStreamWire.encodePointerInput(x: x, y: y, buttons: buttons)
        }
    }

    func sendScrollInput(
        direction: GlassyStreamScrollDirection,
        steps: UInt16
    ) {
        sendAuthenticated(kind: .scrollInput) {
            try GlassyStreamWire.encodeScrollInput(direction: direction, steps: steps)
        }
    }

    func sendKeyInput(keysym: UInt32, isDown: Bool) {
        sendAuthenticated(kind: .keyInput) {
            GlassyStreamWire.encodeKeyInput(keysym: keysym, isDown: isDown)
        }
    }

    func sendTextInput(
        _ text: String,
        modifiers: GlassyStreamTextModifiers = []
    ) {
        sendAuthenticated(kind: .textInput) {
            try GlassyStreamWire.encodeTextInput(text, modifiers: modifiers)
        }
    }

    private func start(configuration: GlassyStreamConnectionConfiguration,
                       callbackQueue: DispatchQueue,
                       callbacks: GlassyStreamClientCallbacks) {
        guard connection == nil, routeRace == nil else {
            callbackQueue.async {
                callbacks.onCompletion(.failure(.alreadyConnecting))
            }
            return
        }

        if let bootstrapCredential = configuration.bootstrapCredential {
            let validationError: GlassyStreamClientError?
            switch bootstrapCredential {
            case .oneTimeCode(let pairingCode):
                validationError = GlassyStreamWire.normalizedPairingCode(pairingCode) == nil
                    ? .invalidPairingCode
                    : nil
            case .password(let password):
                if !GlassyStreamEndpoint.isRecognizedTailscaleEndpoint(
                    configuration.endpoint
                ) {
                    validationError = .pairingPasswordRequiresTailscale
                } else {
                    validationError = GlassyStreamPairingPassword.validated(password) == nil
                        ? .invalidPairingPassword
                        : nil
                }
            }

            if let validationError {
                callbackQueue.async {
                    callbacks.onCompletion(.failure(validationError))
                }
                return
            }
        }

        if let expectedHostIdentifier = configuration.expectedHostIdentifier,
           expectedHostIdentifier.count != GlassyStreamWire.identifierLength {
            callbackQueue.async {
                callbacks.onCompletion(.failure(.protocolViolation(
                    "the expected host identifier is not 16 bytes"
                )))
            }
            return
        }

        guard configuration.authenticationTimeout.isFinite,
              configuration.authenticationTimeout > 0 else {
            callbackQueue.async {
                callbacks.onCompletion(.failure(.protocolViolation(
                    "the authentication timeout must be finite and positive"
                )))
            }
            return
        }

        generation = UUID()
        let activeGeneration = generation
        let authenticationTimeout = configuration.authenticationTimeout
        self.configuration = configuration
        self.callbackQueue = DispatchQueue(
            label: "dev.bunn.glassydesk.glassy-stream.callbacks.\(activeGeneration.uuidString)",
            target: callbackQueue
        )
        self.callbacks = callbacks
        receiveBuffer.removeAll(keepingCapacity: true)
        lastInboundSequence = 0
        nextOutboundSequence = 1
        maximumInboundPayloadLength = GlassyStreamWire.maximumHandshakePayloadLength
        supportsStreamQuality = false
        supportsCursorPositionUpdates = false
        selectedEndpoint = nil
        state = .connecting

        let usesPassword: Bool
        if case .password? = configuration.bootstrapCredential { usesPassword = true }
        else { usesPassword = false }
        let endpoints = ([configuration.endpoint] + configuration.fallbackEndpoints).filter {
            !usesPassword || GlassyStreamEndpoint.isRecognizedTailscaleEndpoint($0)
        }
        let race = GlassyStreamRouteRace(
            endpoints: endpoints,
            expectedHostIdentifier: configuration.expectedHostIdentifier,
            requiresVPNInterface: usesPassword,
            queue: queue
        ) { [weak self] result in
            guard let self, activeGeneration == generation, self.callbacks != nil,
                  case .connecting = state else {
                if case let .success(selection) = result { selection.transport.cancel() }
                return
            }
            switch result {
            case let .failure(error):
                finish(.failure(error), generation: activeGeneration)
            case let .success(selection):
                guard let selectedConnection = selection.transport.networkConnection else {
                    selection.transport.cancel()
                    finish(.failure(.connectionClosed), generation: activeGeneration)
                    return
                }
                routeRace = nil
                connection = selectedConnection
                selectedEndpoint = selection.transport.endpoint
                installConnectionStateHandler(selectedConnection, generation: activeGeneration)
                state = .awaitingServerHello
                scheduleAuthenticationTimeout(after: authenticationTimeout, generation: activeGeneration)
                receiveBuffer = selection.prefetchedData
                do {
                    // Only the selected route enters this method, so the
                    // bootstrap proof is produced and sent at most once.
                    try processReceiveBuffer(generation: activeGeneration)
                    receiveNext(generation: activeGeneration)
                } catch {
                    finish(.failure(clientError(error)), generation: activeGeneration)
                }
            }
        }
        routeRace = race
        AppLog.session.info("Selecting a reachable Glassy Host route")
        race.start()
    }

    private func installConnectionStateHandler(_ connection: NWConnection, generation activeGeneration: UUID) {
        connection.viabilityUpdateHandler = { [weak self, weak connection] viable in
            guard let self, let connection, !viable,
                  activeGeneration == generation, connection === self.connection,
                  case .authenticated = state else { return }
            finish(.failure(.connectionFailed("The connection route is no longer available.")),
                   generation: activeGeneration)
        }
        connection.stateUpdateHandler = { [weak self, weak connection] networkState in
            guard let self, let connection,
                  activeGeneration == generation,
                  connection === self.connection else { return }
            switch networkState {
            case let .failed(error):
                finish(.failure(.connectionFailed(error.localizedDescription)),
                       generation: activeGeneration)
            case let .waiting(error):
                // A streaming connection that enters `waiting` can otherwise
                // remain half-open indefinitely after Wi-Fi or app lifecycle
                // transitions. End this transport and let the session's
                // bounded reconnect policy establish a fresh one.
                if case .authenticated = self.state {
                    finish(.failure(.connectionFailed(error.localizedDescription)),
                           generation: activeGeneration)
                }
            case .cancelled:
                if self.connection != nil {
                    finish(.failure(.connectionClosed), generation: activeGeneration)
                }
            default:
                break
            }
        }
    }

    private func receiveNext(generation activeGeneration: UUID) {
        guard activeGeneration == generation, let connection else { return }
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection,
                  activeGeneration == generation,
                  connection === self.connection else { return }

            if let data, !data.isEmpty {
                receiveBuffer.append(data)
                do {
                    try processReceiveBuffer(generation: activeGeneration)
                } catch {
                    finish(.failure(clientError(error)), generation: activeGeneration)
                    return
                }
            }

            if let error {
                finish(.failure(.connectionFailed(error.localizedDescription)),
                       generation: activeGeneration)
                return
            }
            if isComplete {
                finish(.failure(.connectionClosed), generation: activeGeneration)
                return
            }
            if receiveBuffer.count > maximumInboundPayloadLength + GlassyStreamWire.headerLength {
                finish(.failure(.protocolViolation("receive buffer exceeded its limit")),
                       generation: activeGeneration)
                return
            }
            receiveNext(generation: activeGeneration)
        }
    }

    private func processReceiveBuffer(generation activeGeneration: UUID) throws {
        while let frame = try GlassyStreamWire.decodeNextFrame(
            from: &receiveBuffer,
            maximumPayloadLength: maximumInboundPayloadLength
        ) {
            guard frame.sequence > lastInboundSequence else {
                throw GlassyStreamClientError.protocolViolation("replayed or out-of-order sequence")
            }
            lastInboundSequence = frame.sequence

            if frame.kind == .protocolError {
                guard !frame.flags.contains(.encrypted) else {
                    throw GlassyStreamClientError.protocolViolation("unexpected encrypted error")
                }
                throw GlassyStreamClientError.authenticationRejected(
                    GlassyStreamWire.decodeProtocolError(frame.payload)
                )
            }

            switch state {
            case .idle:
                throw GlassyStreamClientError.protocolViolation("message arrived after disconnect")
            case .connecting:
                throw GlassyStreamClientError.protocolViolation("message arrived before TCP connection was ready")
            case .awaitingServerHello:
                try handleServerHello(frame, generation: activeGeneration)
            case let .awaitingAuthentication(pending):
                try handleAuthenticationAccepted(frame, pending: pending)
            case let .authenticated(material):
                try handleAuthenticated(frame, material: material)
            }
        }
    }

    private func handleServerHello(_ frame: GlassyStreamWire.Frame,
                                   generation activeGeneration: UUID) throws {
        guard frame.sequence == 1,
              frame.kind == .serverHello,
              frame.flags.isEmpty else {
            throw GlassyStreamClientError.protocolViolation("expected plaintext ServerHello")
        }
        guard let configuration else {
            throw GlassyStreamClientError.cancelled
        }
        let serverHello = try GlassyStreamWire.decodeServerHello(frame.payload)
        let capabilities = GlassyStreamWire.Capabilities(rawValue: serverHello.capabilities)
        let requiredCapabilities: GlassyStreamWire.Capabilities = [
            .h264AVCC,
            .encryptedMedia,
            .directInput
        ]
        let mediaCapabilities: GlassyStreamWire.Capabilities = [
            .h264AVCC,
            .encryptedMedia
        ]
        guard capabilities.contains(requiredCapabilities) else {
            if capabilities.contains(mediaCapabilities) {
                throw GlassyStreamClientError.directInputUnsupported
            }
            throw GlassyStreamClientError.protocolViolation(
                "host does not advertise encrypted H.264/AVCC"
            )
        }
        if let expectedHostIdentifier = configuration.expectedHostIdentifier,
           serverHello.hostIdentifier != expectedHostIdentifier {
            throw GlassyStreamClientError.hostIdentityMismatch
        }

        let storedCredential = try credentialStore.credential(
            savedMachineID: configuration.savedMachineID,
            hostIdentifier: serverHello.hostIdentifier
        )
        let clientIdentifier: Data
        if let storedCredential {
            clientIdentifier = storedCredential.clientIdentifier
        } else {
            clientIdentifier = try secureRandomData(count: GlassyStreamWire.identifierLength)
        }

        var credential: Data
        let method: GlassyStreamWire.AuthenticationMethod
        let resumedSession: Bool
        if let bootstrapCredential = configuration.bootstrapCredential {
            switch bootstrapCredential {
            case .oneTimeCode(let suppliedCode):
                guard let code = GlassyStreamWire.normalizedPairingCode(suppliedCode) else {
                    throw GlassyStreamClientError.invalidPairingCode
                }
                credential = Data(code.utf8)
                method = .pairingCode
            case .password(let suppliedPassword):
                guard GlassyStreamEndpoint.isRecognizedTailscaleEndpoint(
                    selectedEndpoint ?? configuration.endpoint
                ), connection?.currentPath?.usesInterfaceType(.other) == true else {
                    throw GlassyStreamClientError.pairingPasswordRequiresTailscale
                }
                guard capabilities.contains(.pairingPassword) else {
                    throw GlassyStreamClientError.pairingPasswordUnsupported
                }
                credential = try GlassyStreamPairingPassword.deriveCredential(
                    from: suppliedPassword,
                    hostIdentifier: serverHello.hostIdentifier
                )
                method = .pairingPasswordV1
            }
            resumedSession = false
        } else if let storedCredential {
            credential = storedCredential.resumeSecret
            method = .resumeSecret
            resumedSession = true
        } else {
            throw GlassyStreamClientError.pairingCodeRequired(hostName: serverHello.serverName)
        }
        defer {
            credential.resetBytes(in: credential.startIndex..<credential.endIndex)
        }

        // The bootstrap credential has served its only purpose. Keep the
        // non-sensitive connection settings needed after authentication, but
        // release the user's code or password before waiting on the network.
        self.configuration = configuration.withoutBootstrapCredential()

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let serverPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            serverPublicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: serverHello.serverPublicKey
            )
        } catch {
            throw GlassyStreamClientError.protocolViolation("invalid host public key")
        }
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: serverPublicKey)
        let emptyProofHello = GlassyStreamWire.ClientHello(
            clientIdentifier: clientIdentifier,
            clientNonce: try secureRandomData(count: GlassyStreamWire.nonceLength),
            clientPublicKey: privateKey.publicKey.rawRepresentation,
            authenticationMethod: method,
            pairingWindow: serverHello.pairingWindow,
            clientName: configuration.clientName,
            proof: Data()
        )
        let transcript = try GlassyStreamWire.authenticationTranscript(
            serverHello: serverHello,
            clientHello: emptyProofHello
        )
        let authenticationKey = GlassyStreamWire.authenticationKey(
            sharedSecret: sharedSecret,
            credential: credential,
            transcript: transcript
        )
        let hello = GlassyStreamWire.ClientHello(
            clientIdentifier: emptyProofHello.clientIdentifier,
            clientNonce: emptyProofHello.clientNonce,
            clientPublicKey: emptyProofHello.clientPublicKey,
            authenticationMethod: emptyProofHello.authenticationMethod,
            pairingWindow: emptyProofHello.pairingWindow,
            clientName: emptyProofHello.clientName,
            proof: GlassyStreamWire.authenticationProof(
                authenticationKey: authenticationKey,
                transcript: transcript
            )
        )
        let material = GlassyStreamWire.sessionMaterial(
            sharedSecret: sharedSecret,
            credential: credential,
            transcript: transcript
        )
        state = .awaitingAuthentication(
            PendingAuthentication(material: material,
                                  hostIdentifier: serverHello.hostIdentifier,
                                  hostName: serverHello.serverName,
                                  clientIdentifier: clientIdentifier,
                                  resumedSession: resumedSession,
                                  supportsStreamQuality: capabilities.contains(.streamQualityControl),
                                  supportsCursorPositionUpdates: capabilities.contains(.cursorPositionUpdates))
        )
        try sendPlaintext(GlassyStreamWire.encodeClientHello(hello),
                          kind: .clientHello,
                          flags: [],
                          generation: activeGeneration)
    }

    private func handleAuthenticationAccepted(
        _ frame: GlassyStreamWire.Frame,
        pending: PendingAuthentication
    ) throws {
        guard frame.kind == .authenticationAccepted,
              frame.flags == [.encrypted] else {
            throw GlassyStreamClientError.protocolViolation(
                "expected encrypted AuthenticationAccepted"
            )
        }
        let plaintext = try GlassyStreamWire.open(frame.payload,
                                                  kind: frame.kind,
                                                  flags: frame.flags,
                                                  sequence: frame.sequence,
                                                  material: pending.material,
                                                  serverToClient: true)
        let accepted = try GlassyStreamWire.decodeAuthenticationAccepted(plaintext)
        guard accepted.clientIdentifier == pending.clientIdentifier else {
            throw GlassyStreamClientError.protocolViolation("host echoed a different client identifier")
        }
        guard let configuration else {
            throw GlassyStreamClientError.cancelled
        }

        let credential = GlassyStreamResumeCredential(
            clientIdentifier: accepted.clientIdentifier,
            resumeSecret: accepted.resumeSecret
        )
        do {
            try credentialStore.save(credential,
                                     savedMachineID: configuration.savedMachineID,
                                     hostIdentifier: pending.hostIdentifier)
        } catch {
            // The current encrypted session remains safe. The next connection
            // will simply require the displayed code again.
            AppLog.storage.error("Could not persist Glassy Stream resume credential: \(error.localizedDescription, privacy: .public)")
        }

        maximumInboundPayloadLength = Int(accepted.maximumMediaPayloadLength)
        cancelAuthenticationTimeout()
        state = .authenticated(pending.material)
        supportsStreamQuality = pending.supportsStreamQuality
        supportsCursorPositionUpdates = pending.supportsCursorPositionUpdates
        if pending.supportsStreamQuality {
            try sendEncrypted(
                GlassyStreamWire.encodeStreamQualityRequest(configuration.desiredQuality),
                kind: .streamQualityRequest,
                flags: [],
                material: pending.material,
                generation: generation
            )
        }
        if pending.supportsCursorPositionUpdates {
            try sendEncrypted(
                GlassyStreamWire.encodeCursorPositionSubscription(),
                kind: .cursorPositionSubscription,
                flags: [],
                material: pending.material,
                generation: generation
            )
        }
        deliver(.authenticated(
            GlassyStreamAuthentication(
                hostIdentifier: pending.hostIdentifier,
                hostName: pending.hostName,
                maximumMediaPayloadLength: maximumInboundPayloadLength,
                resumedSession: pending.resumedSession,
                supportsStreamQuality: pending.supportsStreamQuality,
                supportsCursorPositionUpdates: pending.supportsCursorPositionUpdates,
                connectedAddress: connectedAddress
            )
        ))
        AppLog.session.info("Authenticated encrypted Glassy Stream session")
    }

    private func handleAuthenticated(_ frame: GlassyStreamWire.Frame,
                                     material: GlassyStreamWire.SessionMaterial) throws {
        guard frame.flags.contains(.encrypted) else {
            throw GlassyStreamClientError.protocolViolation("received plaintext after authentication")
        }
        let plaintext = try GlassyStreamWire.open(frame.payload,
                                                  kind: frame.kind,
                                                  flags: frame.flags,
                                                  sequence: frame.sequence,
                                                  material: material,
                                                  serverToClient: true)
        switch frame.kind {
        case .videoConfiguration:
            guard !frame.flags.contains(.keyFrame) else {
                throw GlassyStreamClientError.protocolViolation(
                    "video configuration incorrectly carries keyframe flag"
                )
            }
            deliver(.videoConfiguration(
                try GlassyStreamWire.decodeVideoConfiguration(plaintext)
            ))
        case .videoAccessUnit:
            deliver(.videoAccessUnit(
                try GlassyStreamWire.decodeVideoAccessUnit(
                    plaintext,
                    isKeyFrame: frame.flags.contains(.keyFrame)
                )
            ))
        case .pong:
            guard !frame.flags.contains(.keyFrame), plaintext.count <= 64 else {
                throw GlassyStreamClientError.protocolViolation("invalid pong")
            }
            deliver(.pong(plaintext))
        case .cursorPosition:
            guard supportsCursorPositionUpdates else {
                throw GlassyStreamClientError.protocolViolation(
                    "host sent cursor position without advertising support"
                )
            }
            guard !frame.flags.contains(.keyFrame) else {
                throw GlassyStreamClientError.protocolViolation(
                    "cursor position incorrectly carries keyframe flag"
                )
            }
            deliver(.cursorPosition(
                try GlassyStreamWire.decodeCursorPosition(plaintext)
            ))
        default:
            throw GlassyStreamClientError.protocolViolation(
                "message type is invalid in the authenticated server direction"
            )
        }
    }

    private func sendPlaintext(_ payload: Data,
                               kind: GlassyStreamWire.MessageKind,
                               flags: GlassyStreamWire.Flags,
                               generation activeGeneration: UUID) throws {
        let sequence = takeNextOutboundSequence()
        let packet = try GlassyStreamWire.encode(
            GlassyStreamWire.Frame(kind: kind,
                                   flags: flags,
                                   sequence: sequence,
                                   payload: payload)
        )
        send(packet, generation: activeGeneration)
    }

    private func sendAuthenticated(
        kind: GlassyStreamWire.MessageKind,
        makePayload: @escaping @Sendable () throws -> Data
    ) {
        queue.async { [weak self] in
            guard let self,
                  case let .authenticated(material) = state,
                  connection != nil else {
                return
            }

            do {
                try sendEncrypted(
                    makePayload(),
                    kind: kind,
                    flags: [],
                    material: material,
                    generation: generation
                )
            } catch {
                finish(.failure(clientError(error)), generation: generation)
            }
        }
    }

    private func sendEncrypted(_ plaintext: Data,
                               kind: GlassyStreamWire.MessageKind,
                               flags: GlassyStreamWire.Flags,
                               material: GlassyStreamWire.SessionMaterial,
                               generation activeGeneration: UUID) throws {
        let sequence = takeNextOutboundSequence()
        let payload = try GlassyStreamWire.seal(plaintext,
                                                kind: kind,
                                                flags: flags,
                                                sequence: sequence,
                                                material: material,
                                                serverToClient: false)
        let packet = try GlassyStreamWire.encode(
            GlassyStreamWire.Frame(kind: kind,
                                   flags: flags.union(.encrypted),
                                   sequence: sequence,
                                   payload: payload)
        )
        send(packet, generation: activeGeneration)
    }

    private func send(_ packet: Data, generation activeGeneration: UUID) {
        connection?.send(content: packet,
                         completion: .contentProcessed { [weak self] error in
            guard let self, activeGeneration == generation else { return }
            if let error {
                finish(.failure(.connectionFailed(error.localizedDescription)),
                       generation: activeGeneration)
            }
        })
    }

    private func takeNextOutboundSequence() -> UInt64 {
        defer { nextOutboundSequence &+= 1 }
        return nextOutboundSequence
    }

    private func deliver(_ event: GlassyStreamEvent) {
        guard let callbackQueue, let callbacks else { return }
        callbackQueue.async {
            callbacks.onEvent(event)
        }
    }

    private var connectedAddress: GlassyStreamDirectAddress? {
        let endpoint = selectedEndpoint ?? connection?.currentPath?.remoteEndpoint
        if case let .hostPort(host, port) = endpoint {
            return GlassyStreamDirectAddress(host: String(describing: host), port: port.rawValue)
        }
        if case let .hostPort(host, port) = connection?.currentPath?.remoteEndpoint {
            return GlassyStreamDirectAddress(host: String(describing: host), port: port.rawValue)
        }
        return nil
    }

    private func finish(_ result: Result<Void, GlassyStreamClientError>,
                        generation activeGeneration: UUID) {
        guard activeGeneration == generation, callbacks != nil else { return }
        cancelAuthenticationTimeout()
        routeRace?.cancel()
        routeRace = nil
        connection?.stateUpdateHandler = nil
        connection?.viabilityUpdateHandler = nil
        connection?.cancel()
        self.connection = nil
        selectedEndpoint = nil
        state = .idle
        supportsStreamQuality = false
        supportsCursorPositionUpdates = false
        configuration = nil
        receiveBuffer.removeAll(keepingCapacity: true)

        let completionQueue = callbackQueue
        let completionCallbacks = callbacks
        callbackQueue = nil
        callbacks = nil
        completionQueue?.async {
            completionCallbacks?.onCompletion(result)
        }
    }

    private func scheduleAuthenticationTimeout(
        after timeout: TimeInterval,
        generation activeGeneration: UUID
    ) {
        cancelAuthenticationTimeout()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  activeGeneration == generation,
                  connection != nil else {
                return
            }
            guard case .authenticated = state else {
                finish(.failure(.authenticationTimedOut), generation: activeGeneration)
                return
            }
        }
        authenticationTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func cancelAuthenticationTimeout() {
        authenticationTimeoutWorkItem?.cancel()
        authenticationTimeoutWorkItem = nil
    }

    private func secureRandomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let address = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, bytes.count, address)
        }
        guard status == errSecSuccess else {
            throw GlassyStreamClientError.protocolViolation(
                "secure random generator failed with status \(status)"
            )
        }
        return data
    }

    private func clientError(_ error: Error) -> GlassyStreamClientError {
        if let error = error as? GlassyStreamClientError {
            return error
        }
        return .protocolViolation(error.localizedDescription)
    }
}
