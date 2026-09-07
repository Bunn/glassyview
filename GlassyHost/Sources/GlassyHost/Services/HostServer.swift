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
    typealias AdaptiveBitRateHandler = @Sendable (Int?) -> Void
    typealias AuthenticatedClientReplacementHandler = @Sendable () -> Void
    typealias PairedDevicesHandler = @Sendable ([HostPairedDevice]) -> Void

    struct PairingCode: Equatable, Sendable {
        let value: String
        let expiresAt: Date
    }

    private let core: Core
    private let deviceAccessStore: HostDeviceAccessStore
    private let pairingCodeSource = PairingCodeSource()

    init(serviceName: String = Host.current().localizedName ?? "Glassy Desk",
         port: UInt16 = HostProtocol.defaultPort,
         deviceAccessStore: HostDeviceAccessStore = HostDeviceAccessStore()) {
        self.deviceAccessStore = deviceAccessStore
        core = Core(serviceName: serviceName, port: port, deviceAccessStore: deviceAccessStore)
    }

    deinit {
        core.stop()
    }

    /// Starts with a controller-owned 256-bit device-local credential. Repeating
    /// this call with the same secret is idempotent; a different secret safely
    /// replaces the listener and all sessions.
    func start(pairingSecret: Data,
               pairingPasswordCredential: Data? = nil,
               onClientCountChange: @escaping ClientCountHandler = { _ in },
               onStatusChange: @escaping StatusHandler = { _ in }) {
        guard pairingSecret.count >= 32 else {
            onStatusChange(.failed("The pairing secret must contain at least 32 random bytes."))
            return
        }
        guard pairingPasswordCredential == nil
                || pairingPasswordCredential?.count == PairingPasswordPolicy.derivedCredentialLength else {
            onStatusChange(.failed("The pairing password credential must contain exactly 32 bytes."))
            return
        }
        pairingCodeSource.replaceSecret(pairingSecret)
        core.start(pairingSecret: pairingSecret,
                   pairingPasswordCredential: pairingPasswordCredential,
                   onClientCountChange: onClientCountChange,
                   onStatusChange: onStatusChange)
    }

    func stop() {
        core.stop()
    }

    var allowsConnections: Bool { deviceAccessStore.allowsConnections }

    var pairedDevices: [HostPairedDevice] { deviceAccessStore.pairedDevices() }

    /// Persists access before changing the listener. Completion means existing
    /// transports have been retired when access is disabled.
    func setAllowsConnections(_ allowsConnections: Bool) async throws {
        try await core.setAllowsConnections(allowsConnections)
    }

    /// Completion means the revocation is durable and matching transports are
    /// disconnected. Fresh code/password pairing can subsequently restore it.
    func revokeDevice(id: Data) async throws {
        try await core.revokeDevice(id: id)
    }

    func setPairedDevicesHandler(_ handler: PairedDevicesHandler?) {
        core.setPairedDevicesHandler(handler)
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

    /// Updates the optional first-use password without disturbing the listener
    /// or authenticated viewers. Incomplete handshakes are retired so they
    /// cannot finish against a credential that changed underneath them.
    func setPairingPasswordCredential(_ credential: Data?) {
        guard credential == nil
                || credential?.count == PairingPasswordPolicy.derivedCredentialLength else {
            core.reportInvalidPairingPasswordCredential()
            return
        }
        core.setPairingPasswordCredential(credential)
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

    func setAdaptiveBitRateHandler(_ handler: AdaptiveBitRateHandler?) {
        core.setAdaptiveBitRateHandler(handler)
    }

    func setAdaptiveResolutionHandler(_ handler: AdaptiveBitRateHandler?) {
        core.setAdaptiveResolutionHandler(handler)
    }

    func publishStreamStatus(state: HostProtocol.StreamState, accessibilityGranted: Bool) {
        core.publishStreamStatus(state: state, accessibilityGranted: accessibilityGranted)
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
                                  isKeyFrame: Bool,
                                  encodedWidth: Int? = nil) {
        do {
            let payload = try HostProtocol.encodeVideoAccessUnit(
                avccData,
                presentationTimeSeconds: presentationTimeSeconds,
                durationSeconds: durationSeconds
            )
            core.broadcastVideoAccessUnit(payload, isKeyFrame: isKeyFrame, encodedWidth: encodedWidth)
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

    static func makeHostIdentifier(from pairingSecret: Data) -> Data {
        let digest = HMAC<SHA256>.authenticationCode(
            for: Data("Glassy Host identity v1".utf8),
            using: SymmetricKey(data: pairingSecret)
        )
        return Data(digest.prefix(HostProtocol.identifierLength))
    }

    static func listenerFailureMessage(for error: NWError,
                                       port: UInt16 = HostProtocol.defaultPort) -> String {
        if isAddressInUse(error) {
            return "TCP port \(port) is already in use. Quit the other Glassy Desk instance or app using this port. Glassy Desk will retry automatically every 30 seconds."
        }
        return "Glassy Desk could not listen on TCP port \(port): \(error.localizedDescription). It will retry automatically."
    }

    static func isAddressInUse(_ error: NWError) -> Bool {
        if case .posix(.EADDRINUSE) = error {
            return true
        }
        return false
    }
}

struct HostListenerRetryPolicy {
    private static let transientDelays: [TimeInterval] = [1, 2, 4, 8, 15, 30]
    static let addressInUseDelay: TimeInterval = 30

    static func delay(after error: NWError?, attempt: Int) -> TimeInterval {
        if let error, HostServer.isAddressInUse(error) {
            return addressInUseDelay
        }
        let index = min(max(attempt, 0), transientDelays.count - 1)
        return transientDelays[index]
    }
}

// MARK: - Network core

private extension HostServer {
    final class Core: @unchecked Sendable {
        static let logger = HostLog.network

        private static let maximumConnections = 12
        private static let maximumUnauthenticatedConnections = 4
        private static let authenticationTimeout: TimeInterval = 15
        // Preserve the v1 maximum single-frame envelope. Negotiated credit
        // normally limits delivery far below this, but an unusually large IDR
        // must not be rejected forever at the minimum bitrate.
        private static let maximumQueuedBytesPerClient = HostProtocol.maximumPayloadLength + HostProtocol.headerLength + HostProtocol.authenticationTagLength + 65_536
        private static let mediaQueueAgeBudget: TimeInterval = 0.15
        private static let maximumQueuedMessagesPerClient = 24

        private let queue = DispatchQueue(label: "dev.bunn.glassydesk.host.server",
                                          qos: .userInteractive)
        private let serviceName: String
        private let listenerPort: UInt16
        private let deviceAccessStore: HostDeviceAccessStore

        private var listener: NWListener?
        private var listenerRetryWorkItem: DispatchWorkItem?
        private var listenerRetryIdentifier: UUID?
        private var listenerRetryAttempt = 0
        private var generation = UUID()
        private var clients: [UUID: Client] = [:]
        private var authenticatedClientRegistry = HostAuthenticatedClientRegistry()
        private var rootSecret = SymmetricKey(size: .bits256)
        private var rootSecretData: Data?
        private var pairingPasswordCredential: Data?
        private var hostIdentifier = Data(repeating: 0,
                                          count: HostProtocol.identifierLength)
        private var pairingAttemptLimiter = HostPairingAttemptLimiter()
        private var videoBootstrapCache = HostVideoBootstrapCache()
        private var latestCursorPosition: HostProtocol.CursorPosition?
        private let mediaIngress = MediaIngress()
        private var keyFrameRequestHandler: (@Sendable () -> Void)?
        private var remoteInputHandler: RemoteInputHandler?
        private var authenticatedClientReplacementHandler:
            AuthenticatedClientReplacementHandler?
        private var streamQualityHandler: StreamQualityHandler = { _ in }
        private var streamQualityArbitration = HostStreamQualityArbitration()
        private var adaptiveBitRateHandler: AdaptiveBitRateHandler = { _ in }
        private var publishedAdaptiveBitRate: Int?
        private var publishedAdaptiveMaximumWidth: Int?
        private var adaptiveResolutionHandler: AdaptiveBitRateHandler = { _ in }
        private var mediaMaintenanceWorkItem: DispatchWorkItem?
        private var streamState: HostProtocol.StreamState = .stopped
        private var accessibilityGranted = false
        private var inputOwnership = HostInputOwnership()
        private var inputOwnerID: UUID? { inputOwnership.owner }
        private var lastPublishedClientCount = 0
        private var lastStatus: Status = .stopped
        private var clientCountHandler: ClientCountHandler = { _ in }
        private var statusHandler: StatusHandler = { _ in }
        private var pairedDevicesHandler: PairedDevicesHandler = { _ in }

        init(serviceName: String, port: UInt16, deviceAccessStore: HostDeviceAccessStore) {
            self.serviceName = serviceName
            listenerPort = port
            self.deviceAccessStore = deviceAccessStore
        }

        func start(pairingSecret: Data,
                   pairingPasswordCredential: Data?,
                   onClientCountChange: @escaping ClientCountHandler,
                   onStatusChange: @escaping StatusHandler) {
            queue.async { [weak self] in
                guard let self else { return }
                clientCountHandler = onClientCountChange
                statusHandler = onStatusChange

                if rootSecretData == pairingSecret, listener != nil {
                    if self.pairingPasswordCredential != pairingPasswordCredential {
                        setPairingPasswordCredentialLocked(pairingPasswordCredential)
                    }
                    switch lastStatus {
                    case .starting, .listening:
                        onClientCountChange(lastPublishedClientCount)
                        onStatusChange(lastStatus)
                        return
                    case .stopped, .failed:
                        break
                    }
                }
                startLocked(
                    pairingSecret: pairingSecret,
                    pairingPasswordCredential: pairingPasswordCredential
                )
            }
        }

        func stop() {
            queue.async { [weak self] in
                self?.stopLocked(publishStopped: true)
            }
        }

        func setAllowsConnections(_ allowsConnections: Bool) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async { [self] in
                    do {
                        try deviceAccessStore.setAllowsConnections(allowsConnections)
                        if allowsConnections, let rootSecretData {
                            startLocked(pairingSecret: rootSecretData,
                                        pairingPasswordCredential: pairingPasswordCredential)
                        } else if !allowsConnections {
                            stopLocked(publishStopped: true)
                        }
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        func revokeDevice(id: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async { [self] in
                    do {
                        try deviceAccessStore.revoke(identifier: id)
                        let matchingClients = clients.values.filter { $0.clientIdentifier == id }
                        for client in matchingClients {
                            remove(client, publishChanges: false)
                        }
                        publishAuthenticatedClientCountIfNeeded()
                        publishEffectiveStreamQualityIfNeeded()
                        publishPairedDevices()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        func setPairedDevicesHandler(_ handler: PairedDevicesHandler?) {
            queue.async { [weak self] in
                guard let self else { return }
                pairedDevicesHandler = handler ?? { _ in }
                publishPairedDevices()
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

        func setAdaptiveBitRateHandler(_ handler: AdaptiveBitRateHandler?) {
            queue.async { [weak self] in
                guard let self else { return }
                adaptiveBitRateHandler = handler ?? { _ in }
                publishAdaptiveBitRateIfNeeded(force: true)
            }
        }

        func setAdaptiveResolutionHandler(_ handler: AdaptiveBitRateHandler?) {
            queue.async { [weak self] in
                guard let self else { return }
                adaptiveResolutionHandler = handler ?? { _ in }
                publishAdaptiveBitRateIfNeeded(force: true)
            }
        }

        func publishStreamStatus(state: HostProtocol.StreamState, accessibilityGranted: Bool) {
            queue.async { [weak self] in
                guard let self else { return }
                guard streamState != state || self.accessibilityGranted != accessibilityGranted else { return }
                streamState = state
                self.accessibilityGranted = accessibilityGranted
                for client in authenticatedClients { sendStreamStatus(to: client) }
            }
        }

        private func sendStreamStatus(to client: Client) {
            guard client.supportsAdaptiveStream else { return }
            let status = HostProtocol.StreamStatus(state: streamState,
                                                  accessibilityGranted: accessibilityGranted,
                                                  ownsInput: inputOwnerID == client.id)
            _ = enqueueEncrypted(HostProtocol.encodeStreamStatus(status), kind: .hostStreamStatus,
                                 flags: [], policy: .control, for: client)
        }

        private func publishAdaptiveBitRateIfNeeded(force: Bool = false, reason: String = "receiver progress") {
            let adaptiveClients = authenticatedClients.filter(\.supportsAdaptiveStream)
            let width = adaptiveClients.compactMap(\.ratePolicy.maximumCaptureWidth).min()
            if force || width != publishedAdaptiveMaximumWidth {
                publishedAdaptiveMaximumWidth = width
                Self.logger.info("Adaptive capture width limit=\(width ?? 0) reason=\(reason, privacy: .public)")
                adaptiveResolutionHandler(width)
            }
            let budget = adaptiveClients.map(\.ratePolicy.bitRate).min()
            guard force || budget != publishedAdaptiveBitRate else { return }
            publishedAdaptiveBitRate = budget
            Self.logger.info("Adaptive bitrate=\(budget ?? 0) reason=\(reason, privacy: .public)")
            adaptiveBitRateHandler(budget)
        }

        private func scheduleMediaMaintenanceIfNeeded() {
            guard mediaMaintenanceWorkItem == nil,
                  authenticatedClients.contains(where: \.supportsAdaptiveStream) else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                mediaMaintenanceWorkItem = nil
                let now = ProcessInfo.processInfo.systemUptime
                for client in authenticatedClients where client.supportsAdaptiveStream {
                    if client.deliveryWindow.oldestAge(at: now) > client.ratePolicy.congestionAgeBudget(bytes: client.deliveryWindow.frames.first?.bytes ?? 0) {
                        client.ratePolicy.congested(at: now)
                    }
                    let recoveryDeadline = max(8, min(60, Double(client.deliveryWindow.outstandingBytes * 8) / Double(client.ratePolicy.bitRate) * 3))
                    if client.deliveryWindow.oldestAge(at: now) > recoveryDeadline {
                        // A receiver that never drains cannot hold capture or
                        // the only input-controller role indefinitely.
                        remove(client)
                        continue
                    }
                    sendNextPacket(for: client)
                    if client.needsKeyFrame, client.deliveryWindow.hasCredit(bitRate: client.ratePolicy.bitRate, allowsMultipleFrames: !client.ratePolicy.awaitingFirstDelivery) {
                        requestKeyFrameIfNeeded(for: [client])
                    }
                }
                publishAdaptiveBitRateIfNeeded(reason: "receiver stalled")
                scheduleMediaMaintenanceIfNeeded()
            }
            mediaMaintenanceWorkItem = work
            queue.asyncAfter(deadline: .now() + 0.1, execute: work)
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
                guard let self else { return }
                do {
                    try deviceAccessStore.removeAllDevices()
                } catch {
                    // The new root key independently invalidates every old
                    // credential even if cleaning up display metadata fails.
                    Self.logger.error("Could not clear the saved device list after credential rotation")
                }
                startLocked(
                    pairingSecret: pairingSecret,
                    pairingPasswordCredential: nil
                )
                publishPairedDevices()
            }
        }

        func setPairingPasswordCredential(_ credential: Data?) {
            queue.async { [weak self] in
                self?.setPairingPasswordCredentialLocked(credential)
            }
        }

        func reportInvalidPairingSecret() {
            queue.async { [weak self] in
                self?.publishStatus(.failed("The pairing secret must contain at least 32 random bytes."))
            }
        }

        func reportInvalidPairingPasswordCredential() {
            queue.async { [weak self] in
                self?.publishStatus(.failed(
                    "The pairing password credential must contain exactly 32 bytes."
                ))
            }
        }

        func broadcastCodecConfiguration(_ payload: Data) {
            queue.async { [weak self] in
                guard let self else { return }
                videoBootstrapCache.storeCodecConfiguration(payload)
                for client in authenticatedClients where client.isMediaReady {
                    client.removeQueuedVideoPackets()
                    client.needsKeyFrame = true
                    client.keyFrameRequestOutstanding = false
                    _ = enqueueEncrypted(payload,
                                         kind: .videoConfiguration,
                                         flags: [],
                                         policy: .codecConfiguration,
                                         for: client)
                }
                // The encoder emits configuration immediately before its
                // already-encoded IDR. Requesting another here duplicates that
                // large image; maintenance recovers if the IDR is lost.
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

        func broadcastVideoAccessUnit(_ payload: Data, isKeyFrame: Bool, encodedWidth: Int?) {
            let shouldScheduleDrain = mediaIngress.submit(
                VideoBroadcast(payload: payload, isKeyFrame: isKeyFrame, encodedWidth: encodedWidth)
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
                for client in authenticatedClients where client.isMediaReady {
                    if !item.isKeyFrame, client.needsKeyFrame {
                        requestKeyFrameIfNeeded(for: [client])
                        continue
                    }

                    let wasQueued = enqueueEncrypted(item.payload,
                                                     kind: .videoAccessUnit,
                                                     flags: flags,
                                                     policy: policy,
                                                     for: client, encodedWidth: item.encodedWidth)
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
            for client in clients where client.isMediaReady && client.needsKeyFrame
                && !client.keyFrameRequestOutstanding {
                if client.supportsAdaptiveStream,
                   !client.deliveryWindow.hasCredit(bitRate: client.ratePolicy.bitRate, allowsMultipleFrames: !client.ratePolicy.awaitingFirstDelivery) { continue }
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

        private func startLocked(
            pairingSecret: Data,
            pairingPasswordCredential: Data?
        ) {
            stopLocked(publishStopped: false)

            generation = UUID()
            let activeGeneration = generation
            rootSecretData = pairingSecret
            rootSecret = SymmetricKey(data: pairingSecret)
            hostIdentifier = HostServer.makeHostIdentifier(from: pairingSecret)
            self.pairingPasswordCredential = pairingPasswordCredential
            pairingAttemptLimiter.reset()
            guard deviceAccessStore.allowsConnections else {
                publishStatus(.stopped)
                return
            }
            publishStatus(.starting)
            startListenerLocked(activeGeneration: activeGeneration)
        }

        private func setPairingPasswordCredentialLocked(_ credential: Data?) {
            guard pairingPasswordCredential != credential else { return }
            pairingPasswordCredential = credential
            pairingAttemptLimiter.reset()

            // Authentication proofs are bound to the capability and credential
            // snapshot in ServerHello. Retire incomplete handshakes so every
            // attempt observes one coherent password configuration.
            let incompleteClients = clients.values.filter { !$0.isAuthenticated }
            for client in incompleteClients {
                remove(client, publishChanges: false)
            }
            Self.logger.notice(
                "Pairing password \(credential == nil ? "disabled" : "updated", privacy: .public)"
            )
        }

        private func startListenerLocked(activeGeneration: UUID) {
            guard activeGeneration == generation, listener == nil else { return }
            do {
                let tcpOptions = NWProtocolTCP.Options()
                tcpOptions.noDelay = true
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveIdle = 10
                tcpOptions.keepaliveInterval = 5
                tcpOptions.keepaliveCount = 3
                let parameters = NWParameters(tls: nil, tcp: tcpOptions)
                // A single owner makes a saved direct endpoint deterministic.
                // If another process owns the stable port, surface that conflict
                // instead of silently advertising an ambiguous listener.
                parameters.allowLocalEndpointReuse = false
                parameters.includePeerToPeer = true

                guard let port = NWEndpoint.Port(rawValue: listenerPort) else {
                    publishStatus(.failed("TCP port \(listenerPort) is invalid."))
                    return
                }
                let listener = try NWListener(using: parameters, on: port)
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
                if let networkError = error as? NWError {
                    failListenerCreation(networkError)
                } else {
                    let message = "Glassy Desk could not create its TCP listener on port \(listenerPort): \(error.localizedDescription). It will retry automatically."
                    Self.logger.error("Listener creation failed: \(message, privacy: .public)")
                    publishStatus(.failed(message))
                    scheduleListenerRetry(after: nil)
                }
            }
        }

        private func stopLocked(publishStopped: Bool) {
            generation = UUID()
            cancelListenerRetry()
            listenerRetryAttempt = 0
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil

            retireAllClientsLocked()
            if publishStopped {
                publishStatus(.stopped)
            }
        }

        private func retireAllClientsLocked() {
            let hadAuthenticatedClients = authenticatedClientRegistry.activeConnectionCount > 0
            let existingClients = Array(clients.values)
            clients.removeAll(keepingCapacity: true)
            inputOwnership.removeAll()
            mediaMaintenanceWorkItem?.cancel()
            mediaMaintenanceWorkItem = nil
            authenticatedClientRegistry.removeAll()
            for client in existingClients {
                client.authenticationTimeout?.cancel()
                client.connection.stateUpdateHandler = nil
                client.connection.cancel()
                client.isClosed = true
            }
            if hadAuthenticatedClients {
                authenticatedClientReplacementHandler?()
            }
            publishAuthenticatedClientCountIfNeeded(force: true)
            publishEffectiveStreamQualityIfNeeded()
            publishPairedDevices()
        }

        private func handleListenerState(_ state: NWListener.State,
                                         listener: NWListener) {
            switch state {
            case .setup:
                publishStatus(.starting)
            case let .waiting(error):
                if HostServer.isAddressInUse(error) {
                    failListener(error, listener: listener)
                } else {
                    Self.logger.notice("Listener waiting: \(error.localizedDescription, privacy: .public)")
                    publishStatus(.starting)
                }
            case .ready:
                guard let port = listener.port?.rawValue else {
                    failListener(
                        "The Glassy Desk listener did not receive a TCP port. It will retry automatically.",
                        listener: listener,
                        retryAfter: nil
                    )
                    return
                }
                Self.logger.info("Glassy Host listening on port \(port, privacy: .public)")
                cancelListenerRetry()
                listenerRetryAttempt = 0
                publishStatus(.listening(port: port))
            case let .failed(error):
                failListener(error, listener: listener)
            case .cancelled:
                break
            @unknown default:
                failListener(
                    "The Glassy Desk listener entered an unknown state. It will retry automatically.",
                    listener: listener,
                    retryAfter: nil
                )
            }
        }

        private func failListener(_ error: NWError, listener: NWListener) {
            let message = HostServer.listenerFailureMessage(
                for: error,
                port: listenerPort
            )
            failListener(message, listener: listener, retryAfter: error)
        }

        private func failListener(_ message: String,
                                  listener: NWListener,
                                  retryAfter error: NWError?) {
            Self.logger.error("Listener failed: \(message, privacy: .public)")
            if listener === self.listener {
                listener.stateUpdateHandler = nil
                listener.newConnectionHandler = nil
                listener.cancel()
                self.listener = nil
            }
            retireAllClientsLocked()
            publishStatus(.failed(message))
            scheduleListenerRetry(after: error)
        }

        private func failListenerCreation(_ error: NWError) {
            let message = HostServer.listenerFailureMessage(
                for: error,
                port: listenerPort
            )
            Self.logger.error("Listener creation failed: \(message, privacy: .public)")
            publishStatus(.failed(message))
            scheduleListenerRetry(after: error)
        }

        private func scheduleListenerRetry(after error: NWError?) {
            guard listener == nil, rootSecretData != nil else { return }

            cancelListenerRetry()
            let activeGeneration = generation
            let retryIdentifier = UUID()
            let delay = HostListenerRetryPolicy.delay(
                after: error,
                attempt: listenerRetryAttempt
            )
            listenerRetryAttempt += 1
            listenerRetryIdentifier = retryIdentifier

            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      generation == activeGeneration,
                      listenerRetryIdentifier == retryIdentifier,
                      listener == nil else { return }
                listenerRetryWorkItem = nil
                listenerRetryIdentifier = nil
                publishStatus(.starting)
                startListenerLocked(activeGeneration: activeGeneration)
            }
            listenerRetryWorkItem = workItem
            Self.logger.notice("Retrying the Glassy Host listener in \(delay, privacy: .public) seconds")
            queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        private func cancelListenerRetry() {
            listenerRetryWorkItem?.cancel()
            listenerRetryWorkItem = nil
            listenerRetryIdentifier = nil
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
                    capabilities: HostProtocol.advertisedCapabilities(
                        pairingPasswordEnabled: pairingPasswordCredential != nil
                    ).rawValue,
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
                            let isAuthenticationFailure: Bool
                            if let protocolError = error as? HostProtocol.ProtocolError,
                               case .invalidAuthentication = protocolError {
                                isAuthenticationFailure = true
                            } else {
                                isAuthenticationFailure = false
                            }
                            sendErrorAndClose(
                                code: isAuthenticationFailure ? 2 : 1,
                                message: isAuthenticationFailure
                                    ? "Authentication failed."
                                    : "Invalid protocol message.",
                                client: client
                            )
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
                  frame.payload.count <= HostProtocol.maximumHandshakePayloadLength else {
                throw HostProtocol.ProtocolError.invalidAuthentication
            }

            let hello = try HostProtocol.decodeClientHello(frame.payload)
            let isBootstrapPairing = hello.authenticationMethod.isBootstrapPairing
            guard !isBootstrapPairing || pairingAttemptLimiter.isAllowed() else {
                throw HostProtocol.ProtocolError.invalidAuthentication
            }

            let authentication: (
                credential: Data,
                sharedSecret: SharedSecret,
                transcript: Data
            )
            do {
                let publicKey = try Curve25519.KeyAgreement.PublicKey(
                    rawRepresentation: hello.clientPublicKey
                )
                let sharedSecret = try context.privateKey.sharedSecretFromKeyAgreement(
                    with: publicKey
                )
                let transcript = try HostProtocol.authenticationTranscript(
                    serverHello: context.hello,
                    clientHello: hello
                )
                let credential: Data
                switch hello.authenticationMethod {
                case .pairingCode:
                    let currentWindow = HostProtocol.pairingWindow(at: Date())
                    let lowerWindow = min(hello.pairingWindow, currentWindow)
                    let upperWindow = max(hello.pairingWindow, currentWindow)
                    guard upperWindow - lowerWindow <= 1 else {
                        throw HostProtocol.ProtocolError.invalidAuthentication
                    }
                    let code = HostProtocol.pairingCode(
                        rootSecret: rootSecret,
                        window: hello.pairingWindow
                    )
                    credential = Data(code.utf8)
                case .pairingPasswordV1:
                    guard hello.pairingWindow == context.hello.pairingWindow,
                          let pairingPasswordCredential else {
                        throw HostProtocol.ProtocolError.invalidAuthentication
                    }
                    credential = pairingPasswordCredential
                case .resumeSecret:
                    credential = try deviceAccessStore.resumeSecret(
                        rootSecret: rootSecret,
                        identifier: hello.clientIdentifier
                    )
                }

                let authenticationKey = HostProtocol.authenticationKey(
                    sharedSecret: sharedSecret,
                    credential: credential,
                    transcript: transcript
                )
                guard HostProtocol.isValidProof(
                    hello.proof,
                    authenticationKey: authenticationKey,
                    transcript: transcript
                ) else {
                    throw HostProtocol.ProtocolError.invalidAuthentication
                }
                authentication = (credential, sharedSecret, transcript)
            } catch {
                if isBootstrapPairing {
                    pairingAttemptLimiter.recordFailureIfAllowed()
                }
                throw error
            }

            try deviceAccessStore.recordAuthentication(
                identifier: hello.clientIdentifier,
                name: hello.clientName,
                isBootstrapPairing: isBootstrapPairing
            )
            let resumeSecret = try deviceAccessStore.resumeSecret(
                rootSecret: rootSecret,
                identifier: hello.clientIdentifier
            )
            let material = HostProtocol.sessionMaterial(
                sharedSecret: authentication.sharedSecret,
                credential: authentication.credential,
                transcript: authentication.transcript
            )
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
                if inputOwnership.replace(replacedClient.id, with: client.id) {
                    authenticatedClientReplacementHandler?()
                }
                remove(replacedClient, publishChanges: false)
            }

            client.authenticatedAt = ProcessInfo.processInfo.systemUptime
            inputOwnership.add(client.id)

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

            // Modern clients immediately negotiate with feedback; historical
            // clients send quality first. Hold media until that first message
            // so already-sharing capture cannot send a full-size IDR before
            // the bounded preview is negotiated. Passive legacy clients still
            // start after one second, without requiring any new wire message.
            let mediaTimeout = DispatchWorkItem { [weak self, weak client] in
                guard let self, let client, !client.isClosed else { return }
                activateMedia(for: client)
            }
            client.mediaNegotiationTimeout = mediaTimeout
            queue.asyncAfter(deadline: .now() + 1, execute: mediaTimeout)

            Self.logger.info("Authenticated a Glassy viewer")
            publishAuthenticatedClientCountIfNeeded()
            publishEffectiveStreamQualityIfNeeded()
            publishPairedDevices()
            requestKeyFrameIfNeeded(for: [client])
        }

        private func activateMedia(for client: Client) {
            guard !client.isMediaReady, !client.isClosed else { return }
            client.isMediaReady = true
            client.mediaNegotiationTimeout?.cancel()
            client.mediaNegotiationTimeout = nil
            if let payload = videoBootstrapCache.codecConfiguration {
                _ = enqueueEncrypted(payload, kind: .videoConfiguration, flags: [], policy: .codecConfiguration, for: client)
            }
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
            if frame.kind != .streamFeedback { activateMedia(for: client) }
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
            case .streamFeedback:
                let feedback = try HostProtocol.decodeStreamFeedback(plaintext)
                let now = ProcessInfo.processInfo.systemUptime
                let firstFeedback = !client.supportsAdaptiveStream
                // Media sent before opt-in was not retained in the credit ledger.
                guard feedback.latestHandledVideoSequence <= client.latestSentVideoSequence else {
                    throw HostProtocol.ProtocolError.malformedPayload("feedback acknowledges unsent video")
                }
                client.supportsAdaptiveStream = true
                if firstFeedback { client.ratePolicy.observeInitialRoundTrip(now - client.authenticatedAt) }
                let ceiling = HostStreamQualityConfiguration(quality: client.requestedQuality).averageBitRate
                client.ratePolicy.constrain(to: ceiling)
                let acknowledgedBytes = client.deliveryWindow.frames
                    .filter { $0.sequence <= feedback.latestHandledVideoSequence }.reduce(0) { $0 + $1.bytes }
                let wasAwaitingFirstDelivery = client.ratePolicy.awaitingFirstDelivery
                if feedback.latestHandledVideoSequence <= client.deliveryWindow.latestSentSequence,
                   let age = try client.deliveryWindow.acknowledge(sequence: feedback.latestHandledVideoSequence, at: now) {
                    client.ratePolicy.acknowledged(deliveryAge: age,
                                                  queueAge: Double(feedback.callbackQueueAgeMilliseconds) / 1_000,
                                                  ceiling: ceiling, at: now, deliveredBytes: acknowledgedBytes)
                }
                if wasAwaitingFirstDelivery, !client.ratePolicy.awaitingFirstDelivery {
                    // Preview frames are obsolete after their one capacity
                    // sample. Do not let queued copies serialize ahead of the
                    // newly selected configuration.
                    discardQueuedMedia(for: client)
                }
                if firstFeedback {
                    Self.logger.info("Adaptive stream negotiated quality=\(String(describing: client.requestedQuality), privacy: .public)")
                    sendStreamStatus(to: client)
                }
                publishAdaptiveBitRateIfNeeded()
                activateMedia(for: client)
                sendNextPacket(for: client)
                if client.needsKeyFrame { requestKeyFrameIfNeeded(for: [client]) }
                scheduleMediaMaintenanceIfNeeded()
            case .streamQualityRequest:
                let requestedQuality = try HostProtocol.decodeStreamQualityRequest(plaintext)
                guard requestedQuality != client.requestedQuality else { return }
                client.requestedQuality = requestedQuality
                Self.logger.info("Stream quality selected=\(String(describing: requestedQuality), privacy: .public)")
                client.ratePolicy.selectQuality(ceiling: HostStreamQualityConfiguration(quality: requestedQuality).averageBitRate)
                publishAdaptiveBitRateIfNeeded(reason: "viewer selected quality")
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
            case .pointerInput, .scrollInput, .keyInput, .textInput, .clipboardPaste:
                let input = try HostProtocol.decodeRemoteInput(
                    kind: frame.kind,
                    payload: plaintext
                )
                // One explicit input owner prevents another viewer from
                // releasing held buttons/modifiers or interleaving shortcuts.
                if inputOwnerID == client.id { remoteInputHandler?(input) }
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
            _ = try enqueuePacket(PendingPacket(data: payload, kind: kind, flags: flags,
                                                encrypted: false, policy: policy), for: client)
        }

        private func enqueueEncrypted(_ plaintext: Data,
                                      kind: HostProtocol.MessageKind,
                                      flags: HostProtocol.Flags,
                                      policy: SendPolicy,
                                      for client: Client, encodedWidth: Int? = nil) -> Bool {
            guard client.isAuthenticated else { return false }
            do {
                return try enqueuePacket(PendingPacket(data: plaintext, kind: kind, flags: flags,
                                                       encrypted: true, policy: policy, encodedWidth: encodedWidth), for: client)
            } catch {
                Self.logger.error("Could not queue packet: \(error.localizedDescription, privacy: .public)")
                if policy == .control || policy == .codecConfiguration { remove(client) }
                return false
            }
        }

        private func discardQueuedMedia(for client: Client) {
            if client.removeQueuedMediaFrames() {
                client.needsKeyFrame = true
                client.keyFrameRequestOutstanding = false
            }
        }

        private func expireQueuedMedia(for client: Client, now: TimeInterval) {
            if client.pendingPackets.contains(where: { $0.policy.isVideoFrame && now - $0.enqueuedAt > Self.mediaQueueAgeBudget }) {
                discardQueuedMedia(for: client)
            }
        }

        private func enqueuePacket(_ packet: PendingPacket, for client: Client) throws -> Bool {
            guard !client.isClosed else { return false }
            let now = ProcessInfo.processInfo.systemUptime
            expireQueuedMedia(for: client, now: now)
            if packet.policy == .cursorPosition { client.removeQueuedCursorPositions() }
            if packet.kind == .hostStreamStatus { client.removeQueuedPackets(kind: .hostStreamStatus) }
            if packet.policy == .keyFrame {
                // A new independent frame replaces obsolete unsent recovery
                // generations. Codec configuration is kept in front of it.
                discardQueuedMedia(for: client)
            }
            if packet.policy.isVideoFrame {
                // The first preview must be genuinely small even when an
                // existing full-resolution encoder is already sharing.
                if client.supportsAdaptiveStream, client.ratePolicy.awaitingFirstDelivery {
                    let admit = client.ratePolicy.admitPreview(bytes: packet.byteCount, encodedWidth: packet.encodedWidth)
                    publishAdaptiveBitRateIfNeeded(reason: "bounded initial preview")
                    if !admit {
                        client.needsKeyFrame = true
                        client.keyFrameRequestOutstanding = false
                        return false
                    }
                }
                let maximumFrameBytes = client.supportsAdaptiveStream
                    ? max(65_536, client.ratePolicy.bitRate / 8 / 5)
                    : Self.maximumQueuedBytesPerClient
                if packet.byteCount > maximumFrameBytes, packet.policy == .keyFrame,
                   client.supportsAdaptiveStream {
                    let admit = client.ratePolicy.oversizedKeyFrame(encodedWidth: packet.encodedWidth, at: now)
                    publishAdaptiveBitRateIfNeeded(reason: "large keyframe after receiver congestion")
                    if !admit {
                        client.needsKeyFrame = true
                        client.keyFrameRequestOutstanding = false
                        return false
                    }
                    // A large independent image consumes receiver credit until
                    // acknowledged. Its size is not evidence of a slow link.
                }
                if packet.policy == .keyFrame, client.supportsAdaptiveStream {
                    client.ratePolicy.admittedKeyFrame(bytes: packet.byteCount, at: now)
                }
                let queuedFrames = client.pendingPackets.filter { $0.policy.isVideoFrame }.count
                if queuedFrames >= 12 { discardQueuedMedia(for: client) }
                if packet.policy == .deltaFrame, client.needsKeyFrame {
                    requestKeyFrameIfNeeded(for: [client])
                    return false
                }
            }
            if client.totalQueuedBytes + packet.byteCount > Self.maximumQueuedBytesPerClient
                || client.totalQueuedMessageCount + 1 > Self.maximumQueuedMessagesPerClient {
                discardQueuedMedia(for: client)
            }
            guard client.totalQueuedBytes + packet.byteCount <= Self.maximumQueuedBytesPerClient,
                  client.totalQueuedMessageCount + 1 <= Self.maximumQueuedMessagesPerClient else {
                if packet.policy == .deltaFrame || packet.policy == .keyFrame || packet.policy == .cursorPosition { return false }
                throw HostProtocol.ProtocolError.payloadTooLarge(packet.byteCount)
            }
            if packet.policy == .deltaFrame, client.needsKeyFrame { return false }
            // Sequence numbers and authenticated ciphertext do not exist yet,
            // so small control replies can safely pass pending video.
            if packet.policy == .control {
                let index = client.pendingPackets.firstIndex { $0.policy != .control } ?? client.pendingPackets.endIndex
                client.pendingPackets.insert(packet, at: index)
            } else {
                client.pendingPackets.append(packet)
            }
            client.pendingByteCount += packet.byteCount
            sendNextPacket(for: client)
            return true
        }

        private func sendNextPacket(for client: Client) {
            guard !client.isClosed, client.inFlightByteCount == 0 else { return }
            expireQueuedMedia(for: client, now: ProcessInfo.processInfo.systemUptime)
            guard let pending = client.pendingPackets.first else { return }
            if pending.policy.isVideoFrame, client.supportsAdaptiveStream,
               !client.deliveryWindow.hasCredit(bitRate: client.ratePolicy.bitRate, allowsMultipleFrames: !client.ratePolicy.awaitingFirstDelivery) { return }
            client.pendingPackets.removeFirst()
            client.pendingByteCount -= pending.byteCount
            do {
                let sequence = try client.takeNextOutboundSequence()
                let payload: Data
                var flags = pending.flags
                if pending.encrypted {
                    guard case let .authenticated(material) = client.authorizationState else { return }
                    payload = try HostProtocol.seal(pending.data, kind: pending.kind, flags: flags,
                                                    sequence: sequence, material: material, serverToClient: true)
                    flags.insert(.encrypted)
                } else { payload = pending.data }
                let data = try HostProtocol.encode(.init(kind: pending.kind, flags: flags, sequence: sequence, payload: payload))
                client.inFlightByteCount = data.count
                if pending.policy.isVideoFrame {
                    client.latestSentVideoSequence = sequence
                    if client.supportsAdaptiveStream {
                        client.deliveryWindow.sent(sequence: sequence, bytes: data.count, at: ProcessInfo.processInfo.systemUptime)
                    }
                }
                client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
                    guard let self, let client, !client.isClosed else { return }
                    client.inFlightByteCount = 0
                    if error != nil { remove(client) }
                    else { sendNextPacket(for: client) }
                })
            } catch {
                Self.logger.error("Could not send packet: \(error.localizedDescription, privacy: .public)")
                remove(client)
            }
        }

        private func sendErrorAndClose(code: UInt16,
                                       message: String,
                                       client: Client) {
            guard !client.isClosed else { return }
            let payload = (try? HostProtocol.encodeError(code: code, message: message)) ?? Data()
            guard let sequence = try? client.takeNextOutboundSequence() else { remove(client); return }
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
            if inputOwnership.remove(client.id) {
                authenticatedClientReplacementHandler?()
                for remaining in authenticatedClients { sendStreamStatus(to: remaining) }
            }
            client.isClosed = true
            client.authenticationTimeout?.cancel()
            client.mediaNegotiationTimeout?.cancel()
            client.connection.stateUpdateHandler = nil
            client.connection.cancel()
            guard publishChanges else { return }
            publishAuthenticatedClientCountIfNeeded()
            publishEffectiveStreamQualityIfNeeded()
            publishPairedDevices()
        }

        private func publishPairedDevices() {
            let connectedIdentifiers = Set(authenticatedClients.compactMap(\.clientIdentifier))
            pairedDevicesHandler(deviceAccessStore.pairedDevices(connectedIdentifiers: connectedIdentifiers))
        }

        private func publishAuthenticatedClientCountIfNeeded(force: Bool = false) {
            let count = authenticatedClientRegistry.activeConnectionCount
            guard force || count != lastPublishedClientCount else { return }
            lastPublishedClientCount = count
            clientCountHandler(count)
        }

        private func publishEffectiveStreamQualityIfNeeded(force: Bool = false) {
            publishAdaptiveBitRateIfNeeded()
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

        var isVideoFrame: Bool { self == .keyFrame || self == .deltaFrame }
    }

    struct PendingPacket: Sendable {
        let data: Data
        let kind: HostProtocol.MessageKind
        let flags: HostProtocol.Flags
        let encrypted: Bool
        let policy: SendPolicy
        var encodedWidth: Int? = nil
        let enqueuedAt = ProcessInfo.processInfo.systemUptime
        var byteCount: Int { data.count + HostProtocol.headerLength + (encrypted ? HostProtocol.authenticationTagLength : 0) }
    }

    struct VideoBroadcast: Sendable {
        let payload: Data
        let isKeyFrame: Bool
        let encodedWidth: Int?
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
        var mediaNegotiationTimeout: DispatchWorkItem?
        var isMediaReady = false
        var isClosed = false
        var needsKeyFrame = true
        var keyFrameRequestOutstanding = false
        // A client that never sends the optional request retains legacy quality.
        var requestedQuality: HostProtocol.StreamQuality = .best
        // Cursor telemetry is opt-in so older clients receive no new messages.
        var isSubscribedToCursorPosition = false
        var supportsAdaptiveStream = false
        var deliveryWindow = HostMediaDeliveryWindow()
        var ratePolicy = HostAdaptiveRatePolicy()
        var latestSentVideoSequence: UInt64 = 0
        var authenticatedAt: TimeInterval = 0

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

        func takeNextOutboundSequence() throws -> UInt64 {
            guard nextOutboundSequence < UInt64.max else {
                throw HostProtocol.ProtocolError.malformedPayload("session sequence exhausted")
            }
            defer { nextOutboundSequence += 1 }
            return nextOutboundSequence
        }

        @discardableResult
        func removeQueuedDeltaFrames() -> Bool {
            var removedAny = false
            pendingPackets.removeAll { packet in
                guard packet.policy == .deltaFrame else { return false }
                pendingByteCount -= packet.byteCount
                removedAny = true
                return true
            }
            return removedAny
        }
        @discardableResult
        func removeQueuedMediaFrames() -> Bool {
            var removed = false
            pendingPackets.removeAll { packet in
                guard packet.policy.isVideoFrame else { return false }
                pendingByteCount -= packet.byteCount
                removed = true
                return true
            }
            return removed
        }
        func removeQueuedPackets(kind: HostProtocol.MessageKind) {
            pendingPackets.removeAll { packet in
                guard packet.kind == kind else { return false }
                pendingByteCount -= packet.byteCount
                return true
            }
        }
        func removeQueuedVideoPackets() {
            pendingPackets.removeAll { packet in
                switch packet.policy {
                case .codecConfiguration, .keyFrame, .deltaFrame, .cursorPosition:
                    pendingByteCount -= packet.byteCount
                    return true
                case .control:
                    return false
                }
            }
        }

        func removeQueuedCursorPositions() {
            pendingPackets.removeAll { packet in
                guard packet.policy == .cursorPosition else { return false }
                pendingByteCount -= packet.byteCount
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

struct HostPairingAttemptLimiter: Sendable {
    static let maximumFailures = 8
    static let window: TimeInterval = 60

    private(set) var failureDates: [Date] = []

    mutating func isAllowed(at date: Date = Date()) -> Bool {
        discardExpiredFailures(at: date)
        return failureDates.count < Self.maximumFailures
    }

    /// Records only a still-allowed attempt. Requests received while blocked do
    /// not move the window forward, so repeated traffic cannot extend a block.
    @discardableResult
    mutating func recordFailureIfAllowed(at date: Date = Date()) -> Bool {
        discardExpiredFailures(at: date)
        guard failureDates.count < Self.maximumFailures else { return false }
        failureDates.append(date)
        return true
    }

    mutating func reset() {
        failureDates.removeAll(keepingCapacity: true)
    }

    private mutating func discardExpiredFailures(at date: Date) {
        failureDates.removeAll {
            date.timeIntervalSince($0) >= Self.window
        }
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
