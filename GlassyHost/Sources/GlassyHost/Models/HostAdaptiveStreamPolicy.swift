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
    // Cover 60 fps across a ~450 ms internet RTT plus feedback batching. The
    // independent byte window, sized from the measured RTT, still bounds
    // traffic committed to TCP.
    static let maximumFrames = 32

    var outstandingBytes: Int { frames.reduce(0) { $0 + $1.bytes } }
    /// `window` is the delivery time the in-flight bytes may represent. It must
    /// cover the path RTT, or throughput is capped below the selected bitrate.
    func hasCredit(bitRate: Int, window: TimeInterval = 0.2, allowsMultipleFrames: Bool = true) -> Bool {
        (allowsMultipleFrames || frames.isEmpty) && frames.count < Self.maximumFrames
            && outstandingBytes < max(32_768, Int(Double(bitRate) / 8 * window))
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
    private var rateHeadroomSince: TimeInterval?
    private var lastReceiverCongestion: TimeInterval = -.infinity
    private var initialRoundTripTime: TimeInterval = 0
    private var roundTripSamples: [(time: TimeInterval, value: TimeInterval)] = []
    private var lateSince: TimeInterval?

    /// Windowed minimum of acknowledged path latency. Budgets are relative to
    /// it so a distant host's round trip is not mistaken for congestion.
    var roundTripTime: TimeInterval {
        min(0.6, roundTripSamples.map(\.value).min() ?? initialRoundTripTime)
    }

    /// In-flight credit must span the round trip, or delivery is limited to
    /// window/RTT regardless of link capacity and frames back up on the host.
    var creditWindow: TimeInterval { max(0.2, roundTripTime * 2 + 0.05) }

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
        // The first feedback also includes authentication processing, so it
        // overestimates; acknowledged samples replace it with the path minimum.
        initialRoundTripTime = max(0, min(1, age))
    }

    private mutating func observeRoundTrip(deliveryAge: TimeInterval, bytes: Int, at now: TimeInterval) {
        roundTripSamples.removeAll { now - $0.time > 10 }
        // Only frames that fit TCP's initial window measure latency alone. The
        // target bitrate is not the link rate, so subtracting serialization
        // from larger frames produced near-zero RTTs on a slow stream.
        guard bytes <= 4_096 else { return }
        roundTripSamples.append((now, max(0, deliveryAge - 0.03)))
    }

    /// A single large IDR may serialize longer than a delta frame while still
    /// exceeding the selected bitrate. Compare byte delivery, not age alone.
    func congestionAgeBudget(bytes: Int) -> TimeInterval {
        max(0.35, roundTripTime * 1.5 + 0.03 + Double(bytes * 8) / Double(bitRate) * 1.5)
    }

    /// A frame this old with no acknowledgement is an outage, not jitter.
    /// Single TCP retransmissions on a lossy path stall for about one RTO plus
    /// RTT; sustained shortage is detected from acknowledgements instead.
    func stallAgeBudget(bytes: Int) -> TimeInterval {
        max(1.0, roundTripTime * 3 + 0.03 + Double(bytes * 8) / Double(bitRate) * 2)
    }

    mutating func selectQuality(ceiling: Int) {
        let currentPreviewWidth = previewWidth
        let roundTripTime = initialRoundTripTime
        let samples = roundTripSamples
        let needsBootstrap = awaitingFirstDelivery
        self = Self()
        awaitingFirstDelivery = needsBootstrap
        initialRoundTripTime = roundTripTime
        roundTripSamples = samples
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
                // TCP slow start needs about one extra round trip per doubling
                // beyond its ~14.6 KB initial window. On a distant host that,
                // not link capacity, dominates a preview's delivery time.
                let slowStartRounds = deliveredBytes > 14_600
                    ? ceil(log2(Double(deliveredBytes) / 14_600 + 1)) : 0
                let serializationAge = max(0.001, deliveryAge - initialRoundTripTime * (1 + slowStartRounds) - 0.03)
                let measured = Int(Double(deliveredBytes * 8) / serializationAge * 0.8)
                // Sub-100 ms samples are dominated by scheduling, Wi-Fi jitter
                // and feedback batching; a small preview cannot establish a
                // lower capacity than the selected quality. Real congestion
                // is handled continuously and recovers quickly.
                if serializationAge >= 0.1 {
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
        observeRoundTrip(deliveryAge: deliveryAge, bytes: deliveredBytes, at: now)
        var resolutionChanged = false
        if emergencyResolutionLevel > 0, deliveryAge < max(0.20, roundTripTime * 1.25 + 0.03), queueAge < 0.08,
           let resolutionRecoverySince, now - resolutionRecoverySince >= 15,
           now - lastResolutionChange >= 15 {
            emergencyResolutionLevel -= 1
            lastResolutionChange = now
            self.resolutionRecoverySince = nil
            resolutionChanged = true
        }
        if deliveryAge > congestionAgeBudget(bytes: deliveredBytes) || queueAge > 0.12 {
            rateHeadroomSince = nil
            // A retransmission or Wi-Fi burst delays one batch, then the
            // backlog clears. Only lateness that persists across acknowledgements
            // shows the rate exceeds capacity; reacting to each spike pinned
            // jittery internet paths at the floor.
            if lateSince == nil { lateSince = now }
            guard let lateSince, now - lateSince >= max(0.5, roundTripTime * 2) else { return resolutionChanged }
            return congested(at: now) || resolutionChanged
        }
        lateSince = nil
        let timelyAge = max(0.20, roundTripTime * 1.25 + 0.03 + Double(deliveredBytes * 8) / Double(bitRate))
        // One jittery acknowledgement is not congestion, so it pauses growth
        // without discarding the accumulated stable time. Resetting on every
        // marginal sample let a busy 60 fps link stay pinned at a low rate.
        guard deliveryAge < timelyAge, queueAge < 0.08 else { return resolutionChanged }
        // A recovered rate restores capture detail without waiting for a
        // small keyframe, which a busy desktop may never produce.
        if emergencyResolutionLevel > 0, bitRate >= 1_500_000 {
            if rateHeadroomSince == nil { rateHeadroomSince = now }
            if let since = rateHeadroomSince, now - since >= 4, now - lastResolutionChange >= 4 {
                emergencyResolutionLevel -= 1
                lastResolutionChange = now
                rateHeadroomSince = nil
                resolutionRecoverySince = nil
                resolutionChanged = true
            }
        } else {
            rateHeadroomSince = nil
        }
        guard let stableSince else { self.stableSince = now; return resolutionChanged }
        guard now - stableSince >= 1 else { return resolutionChanged }
        self.stableSince = now
        let previous = bitRate
        bitRate = min(ceiling, max(bitRate + 250_000, Int(Double(bitRate) * 1.5)))
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
