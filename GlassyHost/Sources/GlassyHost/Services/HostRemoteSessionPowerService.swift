import Foundation
import IOKit.pwr_mgt

/// Requests the framebuffer/GPU for an authenticated remote viewer before
/// ScreenCaptureKit starts. A Bonjour lookup or an unauthenticated socket must
/// never wake the display. Idle sleep is allowed again after the last viewer.
@MainActor
final class HostRemoteSessionPowerService {
    private let createDisplayAssertion: @Sendable () -> IOPMAssertionID?
    private let declareRemoteActivity: @Sendable (inout IOPMAssertionID) -> Void
    private let releaseAssertion: @Sendable (IOPMAssertionID) -> Void
    private var displayAssertion: IOPMAssertionID?
    private var activityAssertion = IOPMAssertionID(kIOPMNullAssertionID)
    private var isActive = false

    init(
        createDisplayAssertion: @escaping @Sendable () -> IOPMAssertionID? = {
            var assertion = IOPMAssertionID(kIOPMNullAssertionID)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Glassy Desk remote screen session" as CFString,
                &assertion
            )
            guard result == kIOReturnSuccess else {
                HostLog.capture.error("Could not keep the remote display awake: \(result)")
                return nil
            }
            return assertion
        },
        declareRemoteActivity: @escaping @Sendable (inout IOPMAssertionID) -> Void = { assertion in
            let result = IOPMAssertionDeclareUserActivity(
                "Glassy Desk authenticated remote viewer" as CFString,
                kIOPMUserActiveRemote,
                &assertion
            )
            if result != kIOReturnSuccess {
                HostLog.capture.error("Could not wake the remote display: \(result)")
            }
        },
        releaseAssertion: @escaping @Sendable (IOPMAssertionID) -> Void = {
            _ = IOPMAssertionRelease($0)
        }
    ) {
        self.createDisplayAssertion = createDisplayAssertion
        self.declareRemoteActivity = declareRemoteActivity
        self.releaseAssertion = releaseAssertion
    }

    deinit {
        if let displayAssertion { releaseAssertion(displayAssertion) }
        if activityAssertion != kIOPMNullAssertionID { releaseAssertion(activityAssertion) }
    }

    func update(authenticatedClientCount: Int, allowsConnections: Bool) {
        let shouldBeActive = allowsConnections && authenticatedClientCount > 0
        guard shouldBeActive else {
            isActive = false
            if let displayAssertion {
                releaseAssertion(displayAssertion)
                self.displayAssertion = nil
            }
            if activityAssertion != kIOPMNullAssertionID {
                releaseAssertion(activityAssertion)
                activityAssertion = IOPMAssertionID(kIOPMNullAssertionID)
            }
            return
        }

        let wasActive = isActive
        isActive = true
        if !wasActive || activityAssertion == kIOPMNullAssertionID { wakeDisplay() }
        // This assertion also prevents idle system sleep. It doesn't prevent
        // explicit Sleep, lid closure, locking, or the normal login requirement.
        if displayAssertion == nil { displayAssertion = createDisplayAssertion() }
    }

    func wakeDisplay() {
        guard isActive else { return }
        declareRemoteActivity(&activityAssertion)
    }
}
