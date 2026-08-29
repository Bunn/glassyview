import Foundation

/// Arbitrates optimistic local cursor movement and asynchronous host telemetry.
///
/// Glassy Stream input and cursor telemetry travel in opposite TCP directions,
/// so a newly received host position is not necessarily newer than the latest
/// local pointer command. While local input has authority, host samples are
/// quarantined. Host telemetry regains authority only after local pointer input
/// has been quiet for a bounded interval. Coordinate matching alone is
/// intentionally insufficient: on a reversal or circular gesture, a stale
/// sample can have the same coordinates as the newest target.
struct GlassyStreamCursorReconciler {
    static let localAuthorityDuration: Duration = .seconds(5)

    private(set) var latestRemotePosition: GlassyStreamCursorPosition?
    private(set) var pendingLocalPosition: GlassyStreamCursorPosition?
    private var localAuthorityDeadline: ContinuousClock.Instant?

    var preferredPosition: GlassyStreamCursorPosition? {
        pendingLocalPosition ?? latestRemotePosition
    }

    mutating func recordLocalPosition(
        _ position: GlassyStreamCursorPosition,
        at instant: ContinuousClock.Instant
    ) {
        // Even when the user moves back to the last reported host coordinate,
        // older echoes for intermediate local commands may still be in flight.
        // Require a fresh host sample before returning telemetry to authority.
        pendingLocalPosition = position
        localAuthorityDeadline = instant.advanced(by: Self.localAuthorityDuration)
    }

    /// Returns true when the remote position is safe to expose to cursor UI
    /// and use as a future relative-input base.
    mutating func receiveRemotePosition(
        _ position: GlassyStreamCursorPosition,
        at instant: ContinuousClock.Instant
    ) -> Bool {
        if pendingLocalPosition != nil {
            let localAuthorityExpired = localAuthorityDeadline.map {
                instant >= $0
            } ?? true
            guard localAuthorityExpired else { return false }

            pendingLocalPosition = nil
            localAuthorityDeadline = nil
        }

        latestRemotePosition = position
        return true
    }

    mutating func reset() {
        latestRemotePosition = nil
        pendingLocalPosition = nil
        localAuthorityDeadline = nil
    }
}
