import Foundation
import Testing
@testable import GlassyDesk

@MainActor
@Suite("Free session cooldown")
struct FreeSessionLifecycleTests {
    private let start = Date(timeIntervalSince1970: 10_000)

    @Test("A connected free session gets one minute without extending on repeated updates")
    func startsOnce() {
        withLifecycle { lifecycle, _ in
            #expect(lifecycle.startIfNeeded(at: start))
            #expect(!lifecycle.startIfNeeded(at: start.addingTimeInterval(20)))
            #expect(lifecycle.sessionEndDate == start.addingTimeInterval(60))
            #expect(!lifecycle.endIfNeeded(at: start.addingTimeInterval(59.999)))
            #expect(lifecycle.cooldown == nil)
        }
    }

    @Test("Expiry starts exactly 30 seconds of waiting and cannot be applied twice")
    func expiresOnce() {
        withLifecycle { lifecycle, _ in
            lifecycle.startIfNeeded(at: start)
            #expect(lifecycle.endIfNeeded(at: start.addingTimeInterval(60)))
            #expect(lifecycle.sessionEndDate == nil)
            #expect(lifecycle.cooldown?.endDate == start.addingTimeInterval(90))
            #expect(!lifecycle.endIfNeeded(at: start.addingTimeInterval(65)))
            #expect(!lifecycle.startIfNeeded(at: start.addingTimeInterval(65)))
            #expect(lifecycle.cooldown?.endDate == start.addingTimeInterval(90))
        }
    }

    @Test("Restart unlocks at zero and the next minute starts only after connecting")
    func restartBoundary() {
        withLifecycle { lifecycle, _ in
            lifecycle.startIfNeeded(at: start)
            lifecycle.endIfNeeded(at: start.addingTimeInterval(60))
            #expect(!lifecycle.prepareNextSession(at: start.addingTimeInterval(89.999)))
            #expect(lifecycle.prepareNextSession(at: start.addingTimeInterval(90)))
            #expect(!lifecycle.prepareNextSession(at: start.addingTimeInterval(90)))
            #expect(lifecycle.cooldown == nil)
            #expect(lifecycle.sessionEndDate == nil)

            #expect(lifecycle.startIfNeeded(at: start.addingTimeInterval(95)))
            #expect(lifecycle.sessionEndDate == start.addingTimeInterval(155))
            #expect(lifecycle.endIfNeeded(at: start.addingTimeInterval(155)))
            #expect(lifecycle.cooldown?.endDate == start.addingTimeInterval(185))
        }
    }

    @Test("Disconnecting or reopening the screen preserves the original wait")
    func persistsCooldown() {
        withLifecycle { lifecycle, defaults in
            lifecycle.startIfNeeded(at: start)
            lifecycle.endIfNeeded(at: start.addingTimeInterval(60))
            lifecycle.resetActiveSession()
            let reopened = FreeSessionLifecycle(defaults: defaults, now: start.addingTimeInterval(75))
            #expect(reopened.cooldown == lifecycle.cooldown)
            #expect(reopened.cooldown?.remainingSeconds(at: start.addingTimeInterval(75)) == 15)
            #expect(!reopened.startIfNeeded(at: start.addingTimeInterval(75)))
            #expect(!reopened.prepareNextSession(at: start.addingTimeInterval(75)))
        }
    }

    @Test("Returning from the background or paywall does not extend either deadline")
    func delayedExpiry() {
        withLifecycle { lifecycle, _ in
            lifecycle.startIfNeeded(at: start)
            lifecycle.endIfNeeded(at: start.addingTimeInterval(85))
            #expect(lifecycle.cooldown?.remainingSeconds(at: start.addingTimeInterval(85)) == 5)
            #expect(lifecycle.cooldown?.remainingSeconds(at: start.addingTimeInterval(95)) == 0)
            #expect(lifecycle.prepareNextSession(at: start.addingTimeInterval(95)))
        }
    }

    @Test("A completed wait does not block a newly opened session")
    func ignoresExpiredStoredCooldown() {
        withLifecycle { lifecycle, defaults in
            lifecycle.startIfNeeded(at: start)
            lifecycle.endIfNeeded(at: start.addingTimeInterval(60))
            let reopened = FreeSessionLifecycle(defaults: defaults, now: start.addingTimeInterval(90))
            #expect(reopened.cooldown == nil)
            #expect(reopened.startIfNeeded(at: start.addingTimeInterval(90)))
        }
    }

    @Test("Pro access removes both active and persisted limits immediately")
    func clearsLimits() {
        withLifecycle { lifecycle, defaults in
            lifecycle.startIfNeeded(at: start)
            lifecycle.clearLimits()
            #expect(lifecycle.sessionEndDate == nil)
            lifecycle.startIfNeeded(at: start)
            lifecycle.endIfNeeded(at: start.addingTimeInterval(60))
            lifecycle.clearLimits()
            #expect(lifecycle.cooldown == nil)
            let reopened = FreeSessionLifecycle(defaults: defaults, now: start.addingTimeInterval(61))
            #expect(reopened.cooldown == nil)
        }
    }

    @Test("The visible countdown rounds up, reaches zero, and clamps progress")
    func countdownAccuracy() {
        let cooldown = FreeSessionCooldown(endDate: start.addingTimeInterval(30))
        #expect(cooldown.remainingSeconds(at: start) == 30)
        #expect(cooldown.remainingSeconds(at: start.addingTimeInterval(0.1)) == 30)
        #expect(cooldown.remainingSeconds(at: start.addingTimeInterval(1)) == 29)
        #expect(cooldown.remainingSeconds(at: start.addingTimeInterval(29.999)) == 1)
        #expect(cooldown.remainingSeconds(at: start.addingTimeInterval(30)) == 0)
        #expect(cooldown.remainingSeconds(at: start.addingTimeInterval(35)) == 0)
        #expect(cooldown.progress(at: start.addingTimeInterval(-5)) == 0)
        #expect(cooldown.progress(at: start.addingTimeInterval(15)) == 0.5)
        #expect(cooldown.progress(at: start.addingTimeInterval(35)) == 1)
    }

    private func withLifecycle(_ action: (FreeSessionLifecycle, UserDefaults) -> Void) {
        let suiteName = "FreeSessionLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        action(FreeSessionLifecycle(defaults: defaults, now: start), defaults)
    }
}
