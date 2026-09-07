import Foundation

/// One scheduled drain, bounded compressed media, and dependency-aware recovery.
/// The lock protects the mailbox only; user callbacks always run outside it.
final class GlassyStreamEventDelivery: @unchecked Sendable {
    private struct Entry {
        let event: GlassyStreamEvent
        let sequence: UInt64
        let arrived: TimeInterval
        var bytes: Int {
            if case .videoAccessUnit(let unit) = event { return unit.data.count }
            return 0
        }
        var isVideo: Bool { if case .videoAccessUnit = event { return true }; return false }
    }

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let callbacks: GlassyStreamClientCallbacks
    private let onRetired: @Sendable (UInt64, UInt32) -> Void
    private let onRecovery: @Sendable () -> Void
    private let now: @Sendable () -> TimeInterval
    private let maximumFrames: Int
    private let maximumBytes: Int
    private let maximumAge: TimeInterval
    private var entries: [Entry] = []
    private var draining = false
    private var active = true
    private var waitingForKeyFrame = true
    private var recoveryRequested = false

    init(queue: DispatchQueue, callbacks: GlassyStreamClientCallbacks,
         maximumFrames: Int = 3, maximumBytes: Int = 16 * 1_024 * 1_024,
         maximumAge: TimeInterval = 0.15,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         onRetired: @escaping @Sendable (UInt64, UInt32) -> Void = { _, _ in },
         onRecovery: @escaping @Sendable () -> Void = {}) {
        self.queue = queue
        self.callbacks = callbacks
        self.maximumFrames = max(1, maximumFrames)
        self.maximumBytes = max(1, maximumBytes)
        self.maximumAge = max(0.001, maximumAge)
        self.now = now
        self.onRetired = onRetired
        self.onRecovery = onRecovery
    }

    func offer(_ event: GlassyStreamEvent, sequence: UInt64 = 0) {
        let timestamp = now()
        let entry = Entry(event: event, sequence: sequence, arrived: timestamp)
        var retired: [Entry] = []
        var recover = false
        lock.lock()
        guard active else { lock.unlock(); return }
        switch event {
        case .videoConfiguration:
            retired = removeVideoLocked()
            entries.removeAll { if case .videoConfiguration = $0.event { return true }; return false }
            waitingForKeyFrame = true
            recoveryRequested = false
            entries.append(entry)
        case .videoAccessUnit(let unit):
            let media = entries.filter(\.isVideo)
            if media.count >= maximumFrames || media.reduce(0, { $0 + $1.bytes }) + entry.bytes > maximumBytes
                || media.first.map({ timestamp - $0.arrived > maximumAge }) == true {
                retired += removeVideoLocked()
                appendDiscontinuityLocked(at: timestamp)
            }
            if (waitingForKeyFrame && !unit.isKeyFrame) || entry.bytes > maximumBytes {
                retired.append(entry)
                recover = requestRecoveryLocked()
            } else {
                if unit.isKeyFrame { waitingForKeyFrame = false; recoveryRequested = false }
                entries.append(entry)
            }
        case .cursorPosition:
            entries.removeAll { if case .cursorPosition = $0.event { return true }; return false }
            entries.append(entry)
        case .pong:
            entries.removeAll { if case .pong = $0.event { return true }; return false }
            entries.append(entry)
        case .hostStreamStatus:
            entries.removeAll { if case .hostStreamStatus = $0.event { return true }; return false }
            entries.append(entry)
        case .videoDiscontinuity:
            retired = removeVideoLocked()
            appendDiscontinuityLocked(at: timestamp)
            recover = requestRecoveryLocked()
        case .authenticated:
            entries.append(entry)
        }
        let schedule = !draining && !entries.isEmpty
        if schedule { draining = true }
        lock.unlock()
        retire(retired, at: timestamp)
        if recover { onRecovery() }
        if schedule { queue.async { [weak self] in self?.drain() } }
    }

    func cancel() {
        lock.lock()
        active = false
        entries.removeAll()
        lock.unlock()
    }

    var pendingMediaBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.reduce(0) { $0 + $1.bytes }
    }

    private func drain() {
        // Yield after a small batch so layer attachment/reset work can run too.
        for _ in 0..<8 {
            let timestamp = now()
            var retired: [Entry] = []
            var recover = false
            lock.lock()
            guard active, !entries.isEmpty else { draining = false; lock.unlock(); return }
            if entries.first?.isVideo == true, timestamp - entries[0].arrived > maximumAge {
                retired = removeVideoLocked()
                appendDiscontinuityLocked(at: timestamp)
                recover = requestRecoveryLocked()
            }
            let entry = entries.isEmpty ? nil : entries.removeFirst()
            lock.unlock()
            retire(retired, at: timestamp)
            if recover { onRecovery() }
            if let entry {
                callbacks.onEvent(entry.event)
                retire([entry], at: now())
            }
        }
        queue.async { [weak self] in self?.drain() }
    }

    private func removeVideoLocked() -> [Entry] {
        let removed = entries.filter(\.isVideo)
        entries.removeAll(where: \.isVideo)
        waitingForKeyFrame = true
        return removed
    }

    private func appendDiscontinuityLocked(at timestamp: TimeInterval) {
        waitingForKeyFrame = true
        guard !entries.contains(where: { $0.event == .videoDiscontinuity }) else { return }
        entries.append(Entry(event: .videoDiscontinuity, sequence: 0, arrived: timestamp))
    }

    private func requestRecoveryLocked() -> Bool {
        guard !recoveryRequested else { return false }
        recoveryRequested = true
        return true
    }

    private func retire(_ entries: [Entry], at timestamp: TimeInterval) {
        let media = entries.filter { $0.isVideo && $0.sequence > 0 }
        guard let sequence = media.map(\.sequence).max() else { return }
        let age = media.map { max(0, timestamp - $0.arrived) }.max() ?? 0
        onRetired(sequence, UInt32(min(age * 1_000, Double(UInt32.max))))
    }
}
