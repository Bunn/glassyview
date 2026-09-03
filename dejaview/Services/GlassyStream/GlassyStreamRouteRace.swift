import Foundation
import Network

/// A pre-authentication transport. Implementations deliver callbacks on the
/// queue passed to `start`; no candidate can send a pairing credential.
protocol GlassyStreamRouteTransport: AnyObject, Sendable {
    var endpoint: NWEndpoint { get }
    var networkConnection: NWConnection? { get }
    var usesVPNInterface: Bool { get }
    func start(on queue: DispatchQueue, state: @escaping @Sendable (GlassyStreamRouteState) -> Void)
    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, GlassyStreamClientError?) -> Void)
    func detachStateHandler()
    func cancel()
}

enum GlassyStreamRouteState: Sendable {
    case ready
    case failed(GlassyStreamClientError)
}

/// Races a bounded set of routes through ServerHello, then transfers the open
/// winning connection to the encrypted client. All methods run on `queue`.
/// Selection alone is not authentication: the client must still verify the
/// cryptographic handshake before trusting or saving the selected address.
final class GlassyStreamRouteRace: @unchecked Sendable {
    struct Selection: @unchecked Sendable {
        let transport: any GlassyStreamRouteTransport
        let prefetchedData: Data
    }

    typealias Factory = @Sendable (NWEndpoint) -> any GlassyStreamRouteTransport
    typealias Scheduler = @Sendable (TimeInterval, DispatchWorkItem) -> Void

    static let maximumRoutes = 8
    static let stagger: TimeInterval = 0.18
    static let timeout: TimeInterval = 8

    private struct Candidate {
        let transport: any GlassyStreamRouteTransport
        var data = Data()
        var isReceiving = false
    }

    private let queue: DispatchQueue
    private let endpoints: [NWEndpoint]
    private let expectedHostIdentifier: Data?
    private let requiresVPNInterface: Bool
    private let factory: Factory
    private let scheduler: Scheduler
    private let completion: @Sendable (Result<Selection, GlassyStreamClientError>) -> Void
    private var candidates: [Int: Candidate] = [:]
    private var startedIndices = Set<Int>()
    private var failures: [Int: GlassyStreamClientError] = [:]
    private var scheduledWork: [DispatchWorkItem] = []
    private var didStart = false
    private var isFinished = false

    init(
        endpoints: [NWEndpoint],
        expectedHostIdentifier: Data?,
        requiresVPNInterface: Bool = false,
        queue: DispatchQueue,
        factory: @escaping Factory = { GlassyStreamNetworkRoute(endpoint: $0) },
        scheduler: Scheduler? = nil,
        completion: @escaping @Sendable (Result<Selection, GlassyStreamClientError>) -> Void
    ) {
        self.endpoints = endpoints.reduce(into: []) { unique, endpoint in
            guard unique.count < Self.maximumRoutes, !unique.contains(endpoint) else { return }
            unique.append(endpoint)
        }
        self.expectedHostIdentifier = expectedHostIdentifier
        self.requiresVPNInterface = requiresVPNInterface
        self.queue = queue
        self.factory = factory
        self.scheduler = scheduler ?? { delay, work in
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
        self.completion = completion
    }

    deinit {
        scheduledWork.forEach { $0.cancel() }
        candidates.values.forEach { $0.transport.cancel() }
    }

    func start() {
        guard !didStart, !isFinished else { return }
        didStart = true
        guard !endpoints.isEmpty else {
            finish(.failure(.connectionFailed("No usable connection address is available.")))
            return
        }
        if let expectedHostIdentifier,
           expectedHostIdentifier.count != GlassyStreamWire.identifierLength {
            finish(.failure(.protocolViolation("the expected host identifier is not 16 bytes")))
            return
        }
        schedule(after: Self.timeout) { [weak self] in
            guard let self, !isFinished else { return }
            finish(.failure(preferredFailure ?? .connectionFailed("The connection attempts timed out.")))
        }
        for index in endpoints.indices.dropFirst() {
            schedule(after: Double(index) * Self.stagger) { [weak self] in
                self?.startCandidate(index)
            }
        }
        startCandidate(0)
    }

    /// Retires this generation without delivering another result.
    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        retireCandidates()
    }

    private func startCandidate(_ index: Int) {
        guard !isFinished, startedIndices.insert(index).inserted else { return }
        let transport = factory(endpoints[index])
        candidates[index] = Candidate(transport: transport)
        transport.start(on: queue) { [weak self] state in
            guard let self, !isFinished, let candidate = candidates[index] else { return }
            switch state {
            case .ready:
                guard !candidate.isReceiving else { return }
                guard !requiresVPNInterface || candidate.transport.usesVPNInterface else {
                    reject(index, error: .pairingPasswordRequiresTailscale)
                    return
                }
                candidates[index]?.isReceiving = true
                receive(index)
            case let .failed(error):
                reject(index, error: error)
            }
        }
    }

    private func receive(_ index: Int) {
        guard !isFinished, let candidate = candidates[index] else { return }
        let limit = GlassyStreamWire.maximumHandshakePayloadLength + GlassyStreamWire.headerLength
        candidate.transport.receive(maximumLength: limit - candidate.data.count) { [weak self] data, complete, error in
            guard let self, !isFinished, var candidate = candidates[index] else { return }
            if let error {
                reject(index, error: error)
                return
            }
            guard !complete else {
                reject(index, error: .connectionClosed)
                return
            }
            if let data { candidate.data.append(data) }
            guard candidate.data.count <= limit else {
                reject(index, error: .protocolViolation("ServerHello exceeded its limit"))
                return
            }
            candidates[index] = candidate
            do {
                var buffer = candidate.data
                if let frame = try GlassyStreamWire.decodeNextFrame(
                    from: &buffer,
                    maximumPayloadLength: GlassyStreamWire.maximumHandshakePayloadLength
                ) {
                    try validateHello(frame)
                    candidate.transport.detachStateHandler()
                    candidates.removeValue(forKey: index)
                    finish(.success(Selection(transport: candidate.transport, prefetchedData: candidate.data)))
                    return
                }
                guard candidate.data.count < limit else {
                    throw GlassyStreamClientError.protocolViolation("ServerHello exceeded its limit")
                }
                receive(index)
            } catch {
                reject(index, error: error as? GlassyStreamClientError
                    ?? .protocolViolation(error.localizedDescription))
            }
        }
    }

    private func validateHello(_ frame: GlassyStreamWire.Frame) throws {
        if frame.kind == .protocolError, frame.flags.isEmpty {
            throw GlassyStreamClientError.authenticationRejected(
                GlassyStreamWire.decodeProtocolError(frame.payload)
            )
        }
        guard frame.sequence == 1, frame.kind == .serverHello, frame.flags.isEmpty else {
            throw GlassyStreamClientError.protocolViolation("expected plaintext ServerHello")
        }
        let hello = try GlassyStreamWire.decodeServerHello(frame.payload)
        if let expectedHostIdentifier, hello.hostIdentifier != expectedHostIdentifier {
            throw GlassyStreamClientError.hostIdentityMismatch
        }
        let capabilities = GlassyStreamWire.Capabilities(rawValue: hello.capabilities)
        guard capabilities.contains([.h264AVCC, .encryptedMedia]) else {
            throw GlassyStreamClientError.protocolViolation("host does not advertise encrypted H.264/AVCC")
        }
        guard capabilities.contains(.directInput) else {
            throw GlassyStreamClientError.directInputUnsupported
        }
    }

    private func reject(_ index: Int, error: GlassyStreamClientError) {
        guard !isFinished, let candidate = candidates.removeValue(forKey: index) else { return }
        failures[index] = error
        candidate.transport.cancel()
        if let next = endpoints.indices.first(where: { !startedIndices.contains($0) }) {
            startCandidate(next)
        }
        if !isFinished, candidates.isEmpty, startedIndices.count == endpoints.count {
            finish(.failure(preferredFailure ?? error))
        }
    }

    /// Preserve identity/protocol failures instead of hiding them behind a
    /// later route's timeout; ordering is independent of callback timing.
    private var preferredFailure: GlassyStreamClientError? {
        failures.sorted { lhs, rhs in
            let left = Self.failurePriority(lhs.value)
            let right = Self.failurePriority(rhs.value)
            return left == right ? lhs.key < rhs.key : left > right
        }.first?.value
    }

    private static func failurePriority(_ error: GlassyStreamClientError) -> Int {
        switch error {
        case .hostIdentityMismatch: 3
        case .protocolViolation, .unsupportedHostVersion, .directInputUnsupported, .authenticationRejected,
             .pairingPasswordRequiresTailscale: 2
        default: 1
        }
    }

    private func schedule(after delay: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        let work = DispatchWorkItem(block: action)
        scheduledWork.append(work)
        scheduler(delay, work)
    }

    private func finish(_ result: Result<Selection, GlassyStreamClientError>) {
        guard !isFinished else { return }
        isFinished = true
        retireCandidates()
        completion(result)
    }

    private func retireCandidates() {
        scheduledWork.forEach { $0.cancel() }
        scheduledWork.removeAll()
        let retiring = candidates.values.map(\.transport)
        candidates.removeAll()
        retiring.forEach { $0.cancel() }
    }
}

private final class GlassyStreamNetworkRoute: GlassyStreamRouteTransport, @unchecked Sendable {
    let endpoint: NWEndpoint
    let connection: NWConnection
    var networkConnection: NWConnection? { connection }
    var usesVPNInterface: Bool { connection.currentPath?.usesInterfaceType(.other) == true }

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        connection = NWConnection(to: endpoint, using: parameters)
    }

    func start(on queue: DispatchQueue, state: @escaping @Sendable (GlassyStreamRouteState) -> Void) {
        connection.stateUpdateHandler = { networkState in
            switch networkState {
            case .ready: state(.ready)
            case let .failed(error): state(.failed(.connectionFailed(error.localizedDescription)))
            case .cancelled: state(.failed(.connectionClosed))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, GlassyStreamClientError?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, complete, error in
            completion(data, complete, error.map { .connectionFailed($0.localizedDescription) })
        }
    }

    func detachStateHandler() { connection.stateUpdateHandler = nil }
    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}
