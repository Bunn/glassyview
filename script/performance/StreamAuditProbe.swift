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
        if CommandLine.arguments.dropFirst(2).first == "healthy-best" {
            let direct = try await emergencyIdleBootstrapProbe(directory: directory, linkBitsPerSecond: nil)
            let latency = try await emergencyIdleBootstrapProbe(directory: directory, linkBitsPerSecond: 100_000_000, roundTripDelay: 0.1)
            let cached = try await emergencyIdleBootstrapProbe(directory: directory, linkBitsPerSecond: 100_000_000, roundTripDelay: 0.1, prewarm: true)
            let sustained = try await callbackProbe(stall: 0, directory: directory, linkBitsPerSecond: 100_000_000,
                                                    roundTripDelay: 0.1, frameCount: 600)
            let result: [String: Any] = ["unrestricted_best": direct, "best_100ms_rtt": latency, "cached_best_new_viewer_100ms_rtt": cached, "sixty_fps_100ms_rtt": sustained]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
            return
        }
        if CommandLine.arguments.dropFirst(2).first == "slow-bootstrap" {
            let noise = try await emergencyIdleBootstrapProbe(directory: directory)
            let native = try await emergencyIdleBootstrapProbe(directory: directory, inputWidth: 640)
            let desktop = try await emergencyIdleBootstrapProbe(directory: directory, noise: false)
            let result: [String: Any] = ["noise_3840_source": noise, "noise_native_640_source": native, "desktop_pattern_3840_source": desktop]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
            return
        }
        let baseline = try await callbackProbe(stall: 0, directory: directory)
        let stalled = try await callbackProbe(stall: 1, directory: directory)
        let constrained = try await callbackProbe(stall: 0, directory: directory, linkBitsPerSecond: 2_000_000)
        let budgeted = try await callbackProbe(stall: 0, directory: directory, linkBitsPerSecond: 2_000_000,
                                               frameCount: 60, frameBytes: 6_666, framesPerSecond: 15)
        let adaptive = try await callbackProbe(stall: 0, directory: directory, linkBitsPerSecond: 500_000,
                                               frameCount: 90, followsAdaptiveBudget: true)
        let emergency = try await emergencyIdleBootstrapProbe(directory: directory)
        let idle = try await idleKeyFrameProbe()
        let report: [String: Any] = [
            "scope": "Optimized macOS build of production host + iOS transport; synthetic media; no display decode",
            "callback_baseline": baseline,
            "callback_stalled_consumer": stalled,
            "bandwidth_limited_2mbps": constrained,
            "bandwidth_limited_with_lower_synthetic_source_budget": budgeted,
            "adaptive_source_500kbps": adaptive,
            "emergency_idle_bootstrap": emergency,
            "idle_keyframe": idle,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    // The main-queue callback is the same dispatch target used by the iOS
    // session controller. Only the consumer delay and media producer are fake.
    private static func callbackProbe(stall: Double, directory: URL,
                                      linkBitsPerSecond: Int? = nil, roundTripDelay: Double = 0, frameCount: Int = 180,
                                      frameBytes: Int = 25_000, framesPerSecond: Int = 60,
                                      followsAdaptiveBudget: Bool = false) async throws -> [String: Any] {
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
        let budgetEvents = Locked<[Int]>([])
        let sourceBudget = Locked<Int>(2_000_000)
        let needsKeyFrame = Locked<Bool>(true)
        let offeredBytes = Locked<Int>(0)
        host.setKeyFrameRequestHandler { needsKeyFrame.update { $0 = true } }
        host.setAdaptiveBitRateHandler { budget in
            guard let budget else { return }
            sourceBudget.update { $0 = budget }
            budgetEvents.update { $0.append(budget) }
        }
        host.setStreamQualityHandler { quality in qualityRequests.update { $0.append(String(describing: quality)) } }
        let proxy: RateLimitedProxy?
        let connectionPort: UInt16
        if let linkBitsPerSecond {
            let newProxy = try RateLimitedProxy(hostPort: port, bitsPerSecond: linkBitsPerSecond, roundTripDelay: roundTripDelay)
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
            for index in 0..<frameCount {
                let configuration = HostStreamQualityConfiguration(quality: .best, availableBitRate: sourceBudget.update { $0 })
                let fps = followsAdaptiveBudget ? configuration.framesPerSecond : framesPerSecond
                // Synthetic source follows the host budget only in the adaptive
                // scenario. This is a transport/control test, not H.264 quality.
                let bytes = followsAdaptiveBudget ? max(100, configuration.averageBitRate * 7 / 10 / 8 / fps) : frameBytes
                let payload = Data(repeating: 0x55, count: bytes)
                offeredBytes.update { $0 += bytes }
                let requestedKeyFrame = needsKeyFrame.update { value in let result = value; value = false; return result }
                if index == 30 {
                    stats.update { $0.pingSentAt = ProcessInfo.processInfo.systemUptime }
                    client.sendPing(Data([0x42]))
                }
                host.broadcastVideoAccessUnit(payload,
                                              presentationTimeSeconds: ProcessInfo.processInfo.systemUptime,
                                              durationSeconds: 1.0 / Double(fps),
                                              isKeyFrame: requestedKeyFrame || index % 30 == 0)
                try await Task.sleep(for: .nanoseconds(1_000_000_000 / fps))
            }
        }
        try await producer.value
        let producerDuration = ProcessInfo.processInfo.systemUptime - started
        try await Task.sleep(for: .milliseconds(linkBitsPerSecond == nil ? 500 : 3_000))
        let observationDuration = ProcessInfo.processInfo.systemUptime - started
        return stats.update { stats in
            let ordered = stats.ages.sorted()
            let tail = Array(stats.ages.suffix(max(1, stats.ages.count / 3))).sorted()
            return [
                "last_third_p95_callback_age_ms": (tail.isEmpty ? 0 : tail[min(tail.count - 1, Int(Double(tail.count) * 0.95))]) * 1_000,
                "last_third_maximum_callback_age_ms": (tail.last ?? 0) * 1_000,
                "consumer_stall_seconds": stall,
                "frames_offered": frameCount,
                "payload_bytes_per_frame": frameBytes,
                "nominal_source_fps": framesPerSecond,
                "round_trip_delay_ms": roundTripDelay * 1_000,
                "link_bits_per_second": linkBitsPerSecond as Any? ?? NSNull(),
                "producer_duration_seconds": producerDuration,
                "observation_duration_seconds": observationDuration,
                "offered_payload_mbps": Double(offeredBytes.update { $0 } * 8) / producerDuration / 1_000_000,
                "source_follows_adaptive_budget": followsAdaptiveBudget,
                "host_adaptive_bitrate_events": budgetEvents.update { $0 },
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

    /// Real encoded high-entropy media from one retained capture, with no
    /// later capture frames. This tests emergency resize/IDR delivery end-to-end.
    private static func emergencyIdleBootstrapProbe(directory: URL, linkBitsPerSecond: Int? = 500_000, roundTripDelay: Double = 0, inputWidth: Int = 3840, prewarm: Bool = false, noise: Bool = true) async throws -> [String: Any] {
        let hostStatus = AsyncStream<HostServer.Status>.makeStream()
        let host = HostServer(serviceName: "Glassy Emergency Probe", port: 0,
                              deviceAccessStore: HostDeviceAccessStore(fileURL: directory.appendingPathComponent(UUID().uuidString)))
        let configurations = AsyncStream<HostStreamQualityConfiguration>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let limits = Locked<(Int, Int?)>((12_000_000, nil))
        let rates = Locked<[Int]>([]), widths = Locked<[Int]>([])
        let encodedWidths = Locked<[Int]>([])
        let errors = Locked<[String]>([])
        let frameStats = Locked<(Double?, Int, Double?)>((nil, 0, nil))
        let outputWidths = Locked<[Data: Int]>([:])
        let deliveredFullFrames = Locked<Int>(0)
        let encoder = H264Encoder(configuration: HostStreamQualityConfiguration(quality: .best).encoderConfiguration,
                                  outputHandler: { output in
            switch output {
            case .codecConfiguration(let configuration):
                host.broadcastCodecConfiguration(parameterSets: configuration.parameterSets,
                                                   nalUnitHeaderLength: configuration.nalUnitHeaderLength)
            case .accessUnit(let unit):
                if let width = unit.encodedWidth { encodedWidths.update { $0.append(width) }; outputWidths.update { $0[unit.data] = width } }
                host.broadcastVideoAccessUnit(unit.data, presentationTimeSeconds: unit.presentationTimeSeconds,
                                              durationSeconds: unit.durationSeconds, isKeyFrame: unit.isKeyFrame,
                                              encodedWidth: unit.encodedWidth)
            }
        }, errorHandler: { error in errors.update { $0.append(error.localizedDescription) } })
        host.setKeyFrameRequestHandler { encoder.requestKeyFrame() }
        host.setAdaptiveBitRateHandler { budget in
            guard let budget else { return }
            rates.update { $0.append(budget) }
            let configuration = limits.update { value in
                value.0 = budget
                return HostStreamQualityConfiguration(quality: .best, availableBitRate: value.0, maximumCaptureWidth: value.1)
            }
            configurations.continuation.yield(configuration)
        }
        host.setAdaptiveResolutionHandler { width in
            if let width { widths.update { $0.append(width) } }
            let configuration = limits.update { value in
                value.1 = width
                return HostStreamQualityConfiguration(quality: .best, availableBitRate: value.0, maximumCaptureWidth: value.1)
            }
            configurations.continuation.yield(configuration)
        }
        let updater = Task {
            for await configuration in configurations.stream {
                do { try await encoder.updateConfiguration(configuration.encoderConfiguration) }
                catch { errors.update { $0.append(error.localizedDescription) } }
            }
        }
        let secret = Data(repeating: 0x62, count: 32)
        host.start(pairingSecret: secret, onStatusChange: { hostStatus.continuation.yield($0) })
        defer { host.stop(); hostStatus.continuation.finish(); configurations.continuation.finish(); updater.cancel() }
        var port: UInt16?
        for await status in hostStatus.stream {
            if case .listening(let value) = status { port = value; break }
        }
        guard let port, let code = host.currentPairingCode()?.value else { throw ProbeError(message: "Emergency host unavailable") }
        let proxy = try linkBitsPerSecond.map { try RateLimitedProxy(hostPort: port, bitsPerSecond: $0, roundTripDelay: roundTripDelay) }
        let proxyPort = try await proxy?.start() ?? port
        defer { proxy?.stop() }
        let buffer = try noisePixelBuffer(width: inputWidth, height: inputWidth * 9 / 16, noise: noise)
        if prewarm {
            try await encoder.encode(.init(pixelBuffer: buffer, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                           duration: CMTime(value: 1, timescale: 60)))
            for _ in 0..<100 {
                if encodedWidths.update({ $0.contains(inputWidth) }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let authenticated = AsyncStream<Bool>.makeStream()
        let client = GlassyStreamClient(credentialStore: ProbeCredentialStore())
        defer { client.disconnect(); authenticated.continuation.finish() }
        let started = ProcessInfo.processInfo.systemUptime
        client.connect(configuration: .init(endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: proxyPort)!),
                                            savedMachineID: UUID(), bootstrapCredential: .oneTimeCode(code),
                                            expectedHostIdentifier: HostServer.makeHostIdentifier(from: secret)),
                       callbackQueue: .main, callbacks: .init(onEvent: { event in
            switch event {
            case .authenticated: authenticated.continuation.yield(true)
            case .videoAccessUnit(let unit):
                frameStats.update {
                    if $0.0 == nil { $0.0 = ProcessInfo.processInfo.systemUptime; $0.1 = unit.data.count }
                    if outputWidths.update({ $0[unit.data] }) == inputWidth {
                        deliveredFullFrames.update { $0 += 1 }
                        if $0.2 == nil { $0.2 = ProcessInfo.processInfo.systemUptime }
                    }
                }
            default: break
            }
        }, onCompletion: { result in
            if case .failure(let error) = result { errors.update { $0.append(error.localizedDescription) }; authenticated.continuation.yield(false) }
        }))
        var iterator = authenticated.stream.makeAsyncIterator()
        guard await iterator.next() == true else { throw ProbeError(message: "Emergency authentication failed") }
        try await encoder.encode(.init(pixelBuffer: buffer, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                       duration: CMTime(value: 1, timescale: 15)))
        for _ in 0..<200 {
            if frameStats.update({ linkBitsPerSecond == 500_000 ? $0.0 != nil : $0.2 != nil }) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        if linkBitsPerSecond != 500_000 {
            // Keep the real encoder alive across several periodic large IDRs,
            // so good first-frame timing cannot hide later quality collapse.
            for _ in 0..<5 {
                try await Task.sleep(for: .seconds(2))
                encoder.requestKeyFrame()
            }
            try await Task.sleep(for: .seconds(1))
        } else { try await Task.sleep(for: .milliseconds(200)) }
        let captured = frameStats.update { $0 }
        await encoder.finish()
        let latency = captured.0.map { $0 - started }
        let fullLatency = captured.2.map { $0 - started }
        let healthy = linkBitsPerSecond != 500_000
        let passed = latency.map { $0 < 5 } == true && errors.update { $0.isEmpty }
            && (!healthy || (fullLatency.map { $0 < 1.5 } == true && rates.update { $0.allSatisfy { $0 == 12_000_000 } }))
        let report: [String: Any] = ["first_callback_seconds": latency as Any? ?? NSNull(),
                                     "first_keyframe_bytes": captured.1, "rate_changes": rates.update { $0 },
                                     "link_bits_per_second": linkBitsPerSecond as Any? ?? NSNull(), "encoded_widths": encodedWidths.update { $0 },
                                     "round_trip_delay_ms": roundTripDelay * 1_000, "input_width": inputWidth, "cached_full_size_encoder": prewarm, "noise_input": noise,
                                     "full_resolution_callback_seconds": fullLatency as Any? ?? NSNull(),
                                     "observation_duration_seconds": ProcessInfo.processInfo.systemUptime - started,
                                     "full_resolution_frames_delivered": deliveredFullFrames.update { $0 },
                                     "periodic_real_keyframe_requests": healthy ? 5 : 0,
                                     "minimum_periodic_observation_seconds": healthy ? 11 : 0,
                                     "emergency_widths": widths.update { $0 }, "errors": errors.update { $0 },
                                     "passed": passed, "new_capture_frames_after_initial": 0]
        guard passed else { throw ProbeError(message: "Emergency idle bootstrap missed five-second target: \(report)") }
        return report
    }

    private static func noisePixelBuffer(width: Int, height: Int, noise: Bool = true) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw ProbeError(message: "Noise buffer unavailable") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        var random: UInt32 = 0x53AC9127
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let raw = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let bytes = raw.assumingMemoryBound(to: UInt8.self)
            for index in 0..<(CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)) {
                random = random &* 1_664_525 &+ 1_013_904_223
                let row = index / CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let column = index % CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let textStroke = plane == 0 && row % 28 < 3 && column % 320 > 24 && column % 320 < 260
                bytes[index] = noise ? UInt8(truncatingIfNeeded: random >> 24) : (plane == 0 ? (textStroke ? 32 : 230) : 128)
            }
        }
        return buffer
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
    private let oneWayDelay: Double
    private var nextForwardSerializationTime: Double = 0
    private var connections: [NWConnection] = []

    init(hostPort: UInt16, bitsPerSecond: Int, roundTripDelay: Double = 0) throws {
        self.hostPort = hostPort
        self.bitsPerSecond = bitsPerSecond
        oneWayDelay = roundTripDelay / 2
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
            let now = ProcessInfo.processInfo.systemUptime
            let sendAt: Double
            if paced {
                nextForwardSerializationTime = max(now, nextForwardSerializationTime) + Double(data.count * 8) / Double(bitsPerSecond)
                sendAt = nextForwardSerializationTime + oneWayDelay
            } else { sendAt = now + oneWayDelay }
            queue.asyncAfter(deadline: .now() + max(0, sendAt - now)) {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            // Propagation latency is per stream byte, not a stop-and-wait
            // penalty on every 4 KiB chunk. Keep receiving in wire order.
            pump(source: source, destination: destination, paced: paced)
        }
    }
}
