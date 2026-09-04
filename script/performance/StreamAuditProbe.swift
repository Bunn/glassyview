import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import Network

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func update<Result>(_ work: (inout Value) -> Result) -> Result {
        lock.withLock { work(&value) }
    }
}

private struct ProbeCredentialStore: GlassyStreamResumeCredentialStoring {
    func credential(savedMachineID: UUID, hostIdentifier: Data) throws -> GlassyStreamResumeCredential? { nil }
    func save(_ credential: GlassyStreamResumeCredential, savedMachineID: UUID, hostIdentifier: Data) throws {}
    func removeCredential(savedMachineID: UUID, hostIdentifier: Data) throws {}
}

private struct CallbackStats {
    var ages: [Double] = []
    var bytes = 0
    var errors: [String] = []
    var pingSentAt: Double?
    var pongDelay: Double?
}

@main
private enum StreamAuditProbe {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let baseline = try await callbackProbe(stall: 0, directory: directory)
        let stalled = try await callbackProbe(stall: 1, directory: directory)
        let constrained = try await callbackProbe(stall: 0, directory: directory, linkBitsPerSecond: 2_000_000)
        let budgeted = try await callbackProbe(stall: 0, directory: directory, linkBitsPerSecond: 2_000_000,
                                               frameCount: 60, frameBytes: 6_666, framesPerSecond: 15)
        let idle = try await idleKeyFrameProbe()
        let report: [String: Any] = [
            "scope": "Optimized macOS build of production host + iOS transport; synthetic media; no display decode",
            "callback_baseline": baseline,
            "callback_stalled_consumer": stalled,
            "bandwidth_limited_2mbps": constrained,
            "bandwidth_limited_with_lower_synthetic_source_budget": budgeted,
            "idle_keyframe": idle,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    // The main-queue callback is the same dispatch target used by the iOS
    // session controller. Only the consumer delay and media producer are fake.
    private static func callbackProbe(stall: Double, directory: URL,
                                      linkBitsPerSecond: Int? = nil, frameCount: Int = 180,
                                      frameBytes: Int = 25_000, framesPerSecond: Int = 60) async throws -> [String: Any] {
        let statusStream = AsyncStream<HostServer.Status>.makeStream()
        let host = HostServer(serviceName: "Glassy Stream Audit", port: 0,
                              deviceAccessStore: HostDeviceAccessStore(
                                fileURL: directory.appendingPathComponent(UUID().uuidString)))
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        host.start(pairingSecret: secret, onStatusChange: { statusStream.continuation.yield($0) })
        defer { host.stop(); statusStream.continuation.finish() }
        var port: UInt16?
        for await status in statusStream.stream {
            if case .listening(let listeningPort) = status { port = listeningPort; break }
            if case .failed(let message) = status { throw ProbeError(message: message) }
        }
        guard let port, let code = host.currentPairingCode()?.value else {
            throw ProbeError(message: "No listening probe host")
        }
        let qualityRequests = Locked<[String]>([])
        host.setStreamQualityHandler { quality in qualityRequests.update { $0.append(String(describing: quality)) } }
        let proxy: RateLimitedProxy?
        let connectionPort: UInt16
        if let linkBitsPerSecond {
            let newProxy = try RateLimitedProxy(hostPort: port, bitsPerSecond: linkBitsPerSecond)
            connectionPort = try await newProxy.start()
            proxy = newProxy
        } else {
            connectionPort = port
            proxy = nil
        }
        defer { proxy?.stop() }
        let client = GlassyStreamClient(credentialStore: ProbeCredentialStore())
        defer { client.disconnect() }
        let authenticated = AsyncStream<Bool>.makeStream()
        let stats = Locked(CallbackStats())
        client.connect(configuration: .init(endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: connectionPort)!),
                                            savedMachineID: UUID(), bootstrapCredential: .oneTimeCode(code),
                                            expectedHostIdentifier: HostServer.makeHostIdentifier(from: secret)),
                       callbackQueue: .main,
                       callbacks: .init(onEvent: { event in
            switch event {
            case .authenticated: authenticated.continuation.yield(true)
            case .videoAccessUnit(let unit):
                let isFirst = stats.update { $0.ages.isEmpty }
                if isFirst, stall > 0 { Thread.sleep(forTimeInterval: stall) }
                let age = ProcessInfo.processInfo.systemUptime - unit.presentationTime
                stats.update { $0.ages.append(age); $0.bytes += unit.data.count }
            case .pong:
                stats.update {
                    if let sent = $0.pingSentAt { $0.pongDelay = ProcessInfo.processInfo.systemUptime - sent }
                }
            default: break
            }
        }, onCompletion: { result in
            if case .failure(let error) = result {
                stats.update { $0.errors.append(error.localizedDescription) }
                authenticated.continuation.yield(false)
            }
        }))
        var iterator = authenticated.stream.makeAsyncIterator()
        guard await iterator.next() == true else { throw ProbeError(message: "Authentication failed") }
        authenticated.continuation.finish()

        // No decoder is attached: payload bytes exercise framing, encryption,
        // TCP reception and dispatch, not H.264 image correctness or device FPS.
        let started = ProcessInfo.processInfo.systemUptime
        let producer = Task.detached {
            let payload = Data(repeating: 0x55, count: frameBytes)
            for index in 0..<frameCount {
                if index == 30 {
                    stats.update { $0.pingSentAt = ProcessInfo.processInfo.systemUptime }
                    client.sendPing(Data([0x42]))
                }
                host.broadcastVideoAccessUnit(payload,
                                              presentationTimeSeconds: ProcessInfo.processInfo.systemUptime,
                                              durationSeconds: 1.0 / Double(framesPerSecond),
                                              isKeyFrame: index % 30 == 0)
                try await Task.sleep(for: .nanoseconds(1_000_000_000 / framesPerSecond))
            }
        }
        try await producer.value
        let producerDuration = ProcessInfo.processInfo.systemUptime - started
        try await Task.sleep(for: .milliseconds(linkBitsPerSecond == nil ? 500 : 3_000))
        let observationDuration = ProcessInfo.processInfo.systemUptime - started
        return stats.update { stats in
            let ordered = stats.ages.sorted()
            return [
                "consumer_stall_seconds": stall,
                "frames_offered": frameCount,
                "payload_bytes_per_frame": frameBytes,
                "nominal_source_fps": framesPerSecond,
                "link_bits_per_second": linkBitsPerSecond as Any? ?? NSNull(),
                "producer_duration_seconds": producerDuration,
                "observation_duration_seconds": observationDuration,
                "offered_payload_mbps": Double(frameCount * frameBytes * 8) / producerDuration / 1_000_000,
                "frames_delivered": stats.ages.count,
                "frames_over_100ms_old": stats.ages.filter { $0 > 0.1 }.count,
                "frames_over_500ms_old": stats.ages.filter { $0 > 0.5 }.count,
                "maximum_callback_age_ms": (ordered.last ?? 0) * 1_000,
                "p95_callback_age_ms": (ordered.isEmpty ? 0 : ordered[min(ordered.count - 1, Int(Double(ordered.count) * 0.95))]) * 1_000,
                "errors": stats.errors,
                "pong_delay_ms": stats.pongDelay.map { $0 * 1_000 } as Any? ?? NSNull(),
                "host_effective_quality_events": qualityRequests.update { $0 },
            ]
        }
    }

    private static func idleKeyFrameProbe() async throws -> [String: Any] {
        let outputs = Locked<[H264AccessUnit]>([])
        let errors = Locked<[String]>([])
        let encoder = H264Encoder(configuration: .init(expectedFrameRate: 15, averageBitRate: 2_000_000),
                                  outputHandler: { output in
            if case .accessUnit(let unit) = output { outputs.update { $0.append(unit) } }
        }, errorHandler: { error in errors.update { $0.append(error.localizedDescription) } })
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 1_280, 720,
                                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                        &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw ProbeError(message: "Synthetic pixel buffer failed: \(status)")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) {
                memset(base, plane == 0 ? 64 : 128,
                       CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        for index in 0..<3 {
            try await encoder.encode(.init(pixelBuffer: pixelBuffer,
                                           presentationTimeStamp: CMTime(value: Int64(index), timescale: 15),
                                           duration: CMTime(value: 1, timescale: 15)))
        }
        try await Task.sleep(for: .milliseconds(300))
        let before = outputs.update { $0.count }
        encoder.requestKeyFrame()
        try await Task.sleep(for: .seconds(1))
        let withoutNewInput = outputs.update { $0.count - before }
        try await encoder.encode(.init(pixelBuffer: pixelBuffer,
                                       presentationTimeStamp: CMTime(value: 30, timescale: 15),
                                       duration: CMTime(value: 1, timescale: 15)))
        await encoder.finish()
        return [
            "encoded_before_request": before,
            "outputs_during_one_second_without_new_capture": withoutNewInput,
            "next_input_produced_keyframe": outputs.update { $0.last?.isKeyFrame ?? false },
            "encoder_errors": errors.update { $0 },
        ]
    }
}

private struct ProbeError: Error { let message: String }

/// Application-level bandwidth shaper. The forward TCP byte stream is paced
/// in 4 KiB chunks; reverse traffic is unpaced. It models a bandwidth bottleneck
/// and buffering, not packet loss, radio behavior, or a specific Tailscale route.
private final class RateLimitedProxy: @unchecked Sendable {
    private let queue = DispatchQueue(label: "glassy.audit.proxy")
    private let listener: NWListener
    private let hostPort: UInt16
    private let bitsPerSecond: Int
    private var connections: [NWConnection] = []

    init(hostPort: UInt16, bitsPerSecond: Int) throws {
        self.hostPort = hostPort
        self.bitsPerSecond = bitsPerSecond
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        let states = AsyncStream<UInt16?>.makeStream()
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { states.continuation.yield(self?.listener.port?.rawValue) }
            if case .failed = state { states.continuation.yield(nil) }
        }
        listener.newConnectionHandler = { [weak self] downstream in
            guard let self else { return }
            let options = NWProtocolTCP.Options()
            options.noDelay = true
            let upstream = NWConnection(host: "127.0.0.1", port: .init(rawValue: hostPort)!,
                                        using: NWParameters(tls: nil, tcp: options))
            connections.append(contentsOf: [downstream, upstream])
            downstream.start(queue: queue)
            upstream.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.pump(source: upstream, destination: downstream, paced: true)
                    self?.pump(source: downstream, destination: upstream, paced: false)
                }
            }
            upstream.start(queue: queue)
        }
        listener.start(queue: queue)
        defer { states.continuation.finish() }
        var iterator = states.stream.makeAsyncIterator()
        guard let item = await iterator.next(), let port = item else {
            throw ProbeError(message: "Proxy could not listen")
        }
        return port
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

    private func pump(source: NWConnection, destination: NWConnection, paced: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, done, error in
            guard let self, error == nil, !done, let data, !data.isEmpty else { return }
            let delay = paced ? Double(data.count * 8) / Double(bitsPerSecond) : 0
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                destination.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard error == nil else { return }
                    self?.pump(source: source, destination: destination, paced: paced)
                })
            }
        }
    }
}
