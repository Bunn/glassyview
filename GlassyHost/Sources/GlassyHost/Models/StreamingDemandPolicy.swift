import Foundation

/// Reduces authenticated viewer-count changes and explicit user actions into
/// capture lifecycle effects. The network listener owns authentication; this
/// policy deliberately accepts only its authenticated-client count.
struct StreamingDemandPolicy: Equatable, Sendable {
    enum Ownership: Equatable, Sendable {
        /// Capture exists only to serve authenticated viewers.
        case onDemand

        /// The user explicitly asked capture to remain active.
        case manual
    }

    enum Effect: Equatable, Sendable {
        case startCapture(Ownership)
        case stopCapture
        case scheduleOnDemandStop
        case cancelOnDemandStop
    }

    private(set) var authenticatedClientCount = 0
    private(set) var ownership: Ownership?

    var wantsCapture: Bool {
        ownership != nil
    }

    /// Starts on demand only on the first authenticated viewer transition.
    /// Further viewers do not restart capture after an explicit manual stop.
    mutating func authenticatedClientCountChanged(to newCount: Int) -> [Effect] {
        let newCount = max(0, newCount)
        let previousCount = authenticatedClientCount
        guard newCount != previousCount else { return [] }

        authenticatedClientCount = newCount

        if previousCount == 0, newCount > 0 {
            var effects: [Effect] = [.cancelOnDemandStop]
            if ownership == nil {
                ownership = .onDemand
                effects.append(.startCapture(.onDemand))
            }
            return effects
        }

        if previousCount > 0, newCount == 0, ownership == .onDemand {
            return [.scheduleOnDemandStop]
        }

        return []
    }

    /// Makes capture an explicit always-on user choice. This also promotes an
    /// already-running on-demand stream without restarting its media pipeline.
    mutating func requestManualStart() -> [Effect] {
        switch ownership {
        case .manual:
            return []
        case .onDemand:
            ownership = .manual
            return [.cancelOnDemandStop]
        case nil:
            ownership = .manual
            return [.cancelOnDemandStop, .startCapture(.manual)]
        }
    }

    /// An explicit stop wins over current demand. Capture will not restart
    /// until all current viewers leave and a new 0-to-positive transition occurs.
    mutating func requestManualStop() -> [Effect] {
        guard ownership != nil else {
            return [.cancelOnDemandStop]
        }
        ownership = nil
        return [.cancelOnDemandStop, .stopCapture]
    }

    mutating func onDemandStopGraceExpired() -> [Effect] {
        guard authenticatedClientCount == 0, ownership == .onDemand else {
            return []
        }
        ownership = nil
        return [.stopCapture]
    }

    mutating func captureStartFailed() -> [Effect] {
        ownership = nil
        return [.cancelOnDemandStop]
    }

    mutating func forceStop() -> [Effect] {
        ownership = nil
        return [.cancelOnDemandStop, .stopCapture]
    }
}
