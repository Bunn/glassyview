import Foundation

/// Receiver acknowledgements bound bytes already accepted by TCP, independently
/// of the app's pending queue. All timestamps stay on the host monotonic clock.
struct HostMediaDeliveryWindow: Sendable {
    struct SentFrame: Sendable {
        let sequence: UInt64
        let bytes: Int
        let sentAt: TimeInterval
    }
    private(set) var frames: [SentFrame] = []
    private(set) var latestSentSequence: UInt64 = 0
    private(set) var latestAcknowledgedSequence: UInt64 = 0
    // Cover 60 fps across 100 ms RTT plus feedback batching. The independent
    // 200 ms byte window still bounds traffic committed to TCP.
    static let maximumFrames = 16

    var outstandingBytes: Int { frames.reduce(0) { $0 + $1.bytes } }
    func hasCredit(bitRate: Int, allowsMultipleFrames: Bool = true) -> Bool {
        (allowsMultipleFrames || frames.isEmpty) && frames.count < Self.maximumFrames
            && outstandingBytes < max(32_768, bitRate / 8 / 5)
    }
    func oldestAge(at now: TimeInterval) -> TimeInterval {
        frames.first.map { max(0, now - $0.sentAt) } ?? 0
    }
    mutating func sent(sequence: UInt64, bytes: Int, at now: TimeInterval) {
        latestSentSequence = sequence
        frames.append(SentFrame(sequence: sequence, bytes: bytes, sentAt: now))
    }
    /// Duplicate feedback is harmless; future acknowledgements are invalid.
    mutating func acknowledge(sequence: UInt64, at now: TimeInterval) throws -> TimeInterval? {
        guard sequence <= latestSentSequence else {
            throw HostProtocol.ProtocolError.malformedPayload("feedback acknowledges unsent video")
        }
        guard sequence > latestAcknowledgedSequence else { return nil }
        latestAcknowledgedSequence = sequence
        let acknowledged = frames.filter { $0.sequence <= sequence }
        frames.removeAll { $0.sequence <= sequence }
        return acknowledged.first.map { max(0, now - $0.sentAt) }
    }
}

/// Begin at the selected quality and lower it only after receiver progress
/// demonstrates congestion. Frame complexity alone is not a bandwidth signal.
struct HostAdaptiveRatePolicy: Sendable {
    static let minimumBitRate = 350_000
    private(set) var bitRate = 12_000_000
    private(set) var awaitingFirstDelivery = true
    private var previewWidth = 640
    private var lastDecrease: TimeInterval = -.infinity
    private var stableSince: TimeInterval?
    private(set) var emergencyResolutionLevel = 0
    private var lastResolutionChange: TimeInterval = -.infinity
    private var resolutionRecoverySince: TimeInterval?
    private var lastReceiverCongestion: TimeInterval = -.infinity
    private var initialRoundTripTime: TimeInterval = 0

    var maximumCaptureWidth: Int? {
        if awaitingFirstDelivery { return previewWidth }
        return switch emergencyResolutionLevel {
        case 1: 640
        case 2: 320
        default: nil
        }
    }

    /// Bound only the one-time preview, not the chosen stream quality. Real
    /// native 640-pixel noise can exceed five seconds on a 500 kbps link even
    /// though a downsampled desktop is usually much smaller.
    mutating func admitPreview(bytes: Int, encodedWidth: Int?) -> Bool {
        guard awaitingFirstDelivery, let encodedWidth else { return true }
        guard encodedWidth <= previewWidth else { return false }
        if bytes > 200_000, previewWidth > 320 { previewWidth = 320 }
        return encodedWidth <= previewWidth
    }

    /// An IDR can exceed the average-rate window on a healthy connection. Admit
    /// it once against receiver credit. Emergency dimensions require actual
    /// receiver congestion at the rate floor, never just image complexity.
    mutating func oversizedKeyFrame(encodedWidth: Int? = nil, at now: TimeInterval) -> Bool {
        guard !awaitingFirstDelivery else { return encodedWidth.map { $0 <= previewWidth } ?? true }
        guard bitRate == Self.minimumBitRate, now - lastReceiverCongestion < 2 else { return true }
        resolutionRecoverySince = nil
        guard emergencyResolutionLevel < 2 else {
            // An idle recovery may still reference the prior capture tier
            // while ScreenCaptureKit applies a resize. Wait for the actual
            // small encoded image, not just the requested configuration.
            return encodedWidth.map { $0 <= 320 } ?? true
        }
        if now - lastResolutionChange >= 0.5 {
            emergencyResolutionLevel += 1
            lastResolutionChange = now
        }
        return false
    }

    mutating func admittedKeyFrame(bytes: Int, at now: TimeInterval) {
        guard emergencyResolutionLevel > 0 else { return }
        // A next-tier frame has up to four times as many pixels. Require
        // substantial measured headroom before restoring detail, rather than
        // repeatedly oscillating a noisy desktop into oversized keyframes.
        if bytes <= max(65_536, bitRate / 8 / 5) / 6 {
            if resolutionRecoverySince == nil { resolutionRecoverySince = now }
        } else { resolutionRecoverySince = nil }
    }

    mutating func observeInitialRoundTrip(_ age: TimeInterval) {
        initialRoundTripTime = max(0, min(0.25, age))
    }

    /// A single large IDR may serialize longer than a delta frame while still
    /// exceeding the selected bitrate. Compare byte delivery, not age alone.
    func congestionAgeBudget(bytes: Int) -> TimeInterval {
        max(0.35, initialRoundTripTime + 0.03 + Double(bytes * 8) / Double(bitRate) * 1.5)
    }

    mutating func selectQuality(ceiling: Int) {
        let currentPreviewWidth = previewWidth
        let roundTripTime = initialRoundTripTime
        let needsBootstrap = awaitingFirstDelivery
        self = Self()
        awaitingFirstDelivery = needsBootstrap
        initialRoundTripTime = roundTripTime
        previewWidth = currentPreviewWidth
        constrain(to: ceiling)
    }

    mutating func constrain(to ceiling: Int) {
        bitRate = max(Self.minimumBitRate, min(bitRate, ceiling))
    }
    @discardableResult
    mutating func congested(at now: TimeInterval) -> Bool {
        guard !awaitingFirstDelivery else { return false }
        lastReceiverCongestion = now
        stableSince = nil
        guard now - lastDecrease >= 0.5 else { return false }
        lastDecrease = now
        let previous = bitRate
        bitRate = max(Self.minimumBitRate, Int(Double(bitRate) * 0.65))
        return previous != bitRate
    }
    @discardableResult
    mutating func acknowledged(deliveryAge: TimeInterval, queueAge: TimeInterval,
                               ceiling: Int, at now: TimeInterval, deliveredBytes: Int = 0) -> Bool {
        constrain(to: ceiling)
        if awaitingFirstDelivery {
            awaitingFirstDelivery = false
            if deliveredBytes > 0 {
                // Initial feedback measures the authentication round trip.
                // Allow the client's bounded 30 ms feedback batching when
                // estimating serialization instead of mistaking RTT for a
                // throughput limit (or a tiny preview for proof of capacity).
                let serializationAge = max(0.001, deliveryAge - initialRoundTripTime - 0.03)
                let measured = Int(Double(deliveredBytes * 8) / serializationAge * 0.8)
                // Sub-20 ms samples are dominated by scheduling and timer
                // granularity; a tiny flat preview cannot establish a lower
                // capacity than the selected quality.
                if serializationAge >= 0.02 {
                    bitRate = max(Self.minimumBitRate, min(bitRate, measured))
                }
                lastReceiverCongestion = now
                lastDecrease = now
                if bitRate < 700_000 {
                    emergencyResolutionLevel = 1
                    lastResolutionChange = now
                }
            }
            stableSince = now
            return true
        }
        var resolutionChanged = false
        if emergencyResolutionLevel > 0, deliveryAge < 0.20, queueAge < 0.08,
           let resolutionRecoverySince, now - resolutionRecoverySince >= 15,
           now - lastResolutionChange >= 15 {
            emergencyResolutionLevel -= 1
            lastResolutionChange = now
            self.resolutionRecoverySince = nil
            resolutionChanged = true
        }
        if deliveryAge > congestionAgeBudget(bytes: deliveredBytes) || queueAge > 0.12 {
            return congested(at: now)
        }
        let timelyAge = max(0.20, initialRoundTripTime + 0.03 + Double(deliveredBytes * 8) / Double(bitRate))
        guard deliveryAge < timelyAge, queueAge < 0.08 else {
            stableSince = nil
            return resolutionChanged
        }
        guard let stableSince else { self.stableSince = now; return resolutionChanged }
        guard now - stableSince >= 3 else { return resolutionChanged }
        self.stableSince = now
        let previous = bitRate
        bitRate = min(ceiling, max(bitRate + 100_000, Int(Double(bitRate) * 1.2)))
        return bitRate != previous || resolutionChanged
    }
}

/// First authenticated viewer controls the desktop. Later viewers have an
/// explicit read-only role until the owner retires. Resume keeps queue order.
struct HostInputOwnership: Sendable {
    private var viewers: [UUID] = []
    var owner: UUID? { viewers.first }

    mutating func add(_ connection: UUID) {
        if !viewers.contains(connection) { viewers.append(connection) }
    }
    /// Returns whether held input must be released before replacement traffic.
    mutating func replace(_ old: UUID, with new: UUID) -> Bool {
        let ownedInput = owner == old
        if let index = viewers.firstIndex(of: old) { viewers[index] = new }
        else { add(new) }
        return ownedInput
    }
    /// A view-only disconnect cannot disturb the controller's held input.
    mutating func remove(_ connection: UUID) -> Bool {
        let ownedInput = owner == connection
        viewers.removeAll { $0 == connection }
        return ownedInput
    }
    mutating func removeAll() { viewers.removeAll() }
}
