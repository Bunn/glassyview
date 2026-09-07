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
    static let maximumFrames = 3

    var outstandingBytes: Int { frames.reduce(0) { $0 + $1.bytes } }
    func hasCredit(bitRate: Int) -> Bool {
        frames.count < Self.maximumFrames
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

/// Selected quality is a ceiling. Begin conservatively and react faster to
/// congestion than recovery. The rate floor deliberately supports sub-1Mbps.
struct HostAdaptiveRatePolicy: Sendable {
    static let minimumBitRate = 350_000
    private(set) var bitRate = 2_000_000
    private var lastDecrease: TimeInterval = -.infinity
    private var stableSince: TimeInterval?
    private(set) var emergencyResolutionLevel = 0
    private var lastResolutionChange: TimeInterval = -.infinity
    private var resolutionRecoverySince: TimeInterval?
    private var lastOversizedFrameDecrease: TimeInterval = -.infinity

    var maximumCaptureWidth: Int? {
        switch emergencyResolutionLevel {
        case 1: 640
        case 2: 320
        default: nil
        }
    }

    /// Oversized IDRs first reduce the ordinary rate tiers. Only repeated
    /// pressure at the rate floor enables emergency resolution. The final
    /// small tier always permits one IDR, preventing a permanent black hole.
    mutating func oversizedKeyFrame(encodedWidth: Int? = nil, at now: TimeInterval) -> Bool {
        resolutionRecoverySince = nil
        if bitRate > Self.minimumBitRate {
            // Bootstrap must reach a deliverable tier within the presentation
            // deadline. Actual oversized IDRs justify a faster decrease than
            // noisy receiver-age samples; repeated requests are still bounded.
            if now - lastOversizedFrameDecrease >= 0.25 {
                bitRate = max(Self.minimumBitRate, bitRate / 2)
                lastOversizedFrameDecrease = now
                stableSince = nil
            }
            return false
        }
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

    mutating func constrain(to ceiling: Int) {
        bitRate = max(Self.minimumBitRate, min(bitRate, ceiling))
    }
    @discardableResult
    mutating func congested(at now: TimeInterval) -> Bool {
        stableSince = nil
        guard now - lastDecrease >= 0.5 else { return false }
        lastDecrease = now
        let previous = bitRate
        bitRate = max(Self.minimumBitRate, Int(Double(bitRate) * 0.65))
        return previous != bitRate
    }
    @discardableResult
    mutating func acknowledged(deliveryAge: TimeInterval, queueAge: TimeInterval,
                               ceiling: Int, at now: TimeInterval) -> Bool {
        constrain(to: ceiling)
        var resolutionChanged = false
        if emergencyResolutionLevel > 0, deliveryAge < 0.20, queueAge < 0.08,
           let resolutionRecoverySince, now - resolutionRecoverySince >= 15,
           now - lastResolutionChange >= 15 {
            emergencyResolutionLevel -= 1
            lastResolutionChange = now
            self.resolutionRecoverySince = nil
            resolutionChanged = true
        }
        if deliveryAge > 0.30 || queueAge > 0.12 {
            return congested(at: now)
        }
        guard deliveryAge < 0.20, queueAge < 0.08 else {
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
