import Foundation
import Testing
import UIKit
@testable import GlassyDesk

@MainActor
struct AppLockControllerTests {
    @Test
    func turningTheLockOnOrOffRequiresAuthentication() async throws {
        let fixture = try Fixture(results: [.cancelled, .success, .failed("Face ID didn't match."), .success])
        let lock = fixture.controller
        #expect(!lock.isEnabled && !lock.isLocked && !lock.showsCover)

        #expect(await lock.setEnabled(true) == false)
        #expect(!lock.isEnabled)
        #expect(lock.errorMessage == nil, "Cancelling is not an error")

        #expect(await lock.setEnabled(true))
        #expect(lock.isEnabled && !lock.isLocked)
        #expect(fixture.defaults.bool(forKey: AppLockController.isEnabledKey))

        #expect(await lock.setEnabled(false) == false)
        #expect(lock.isEnabled)
        #expect(lock.errorMessage == "Face ID didn't match.")

        #expect(await lock.setEnabled(false))
        #expect(!lock.isEnabled)
        #expect(fixture.reasons.count == 4)
    }

    @Test
    func aDeviceWithoutAPasscodeCannotEnableTheLock() async throws {
        let fixture = try Fixture(method: nil)
        #expect(await fixture.controller.setEnabled(true) == false)
        #expect(fixture.controller.errorMessage?.contains("passcode") == true)
        #expect(fixture.reasons.isEmpty)
    }

    @Test
    func launchStartsLockedAndRelocksOnlyAfterTheDelay() async throws {
        let fixture = try Fixture(results: [.success, .success, .success], enabled: true, delay: .oneMinute)
        let lock = fixture.controller
        #expect(lock.isLocked && lock.showsCover)

        lock.sceneBecameActive()
        try await fixture.waitUntil { !lock.isLocked }
        #expect(!lock.showsCover)

        // App switcher snapshots are covered without locking.
        lock.sceneBecameInactive()
        #expect(lock.showsCover && !lock.isLocked)
        lock.sceneEnteredBackground()
        fixture.advance(by: 59)
        lock.sceneBecameActive()
        #expect(!lock.isLocked && !lock.showsCover)

        lock.sceneEnteredBackground()
        fixture.advance(by: 60)
        lock.sceneBecameActive()
        #expect(lock.isLocked && lock.showsCover)
        try await fixture.waitUntil { !lock.isLocked }
        #expect(fixture.reasons.count == 2)
    }

    @Test
    func aFailedUnlockStaysLockedAndCanBeRetried() async throws {
        let fixture = try Fixture(results: [.failed("Try again."), .success], enabled: true)
        let lock = fixture.controller
        await lock.unlock()
        #expect(lock.isLocked)
        #expect(lock.errorMessage == "Try again.")
        await lock.unlock()
        #expect(!lock.isLocked)
        #expect(lock.errorMessage == nil)
    }

    @Test
    func coverWindowSitsAboveSheetsAndTakesKeyboardFocusOnlyWhileShown() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIWindow(windowScene: scene)
        host.makeKeyAndVisible()
        let fixture = try Fixture(enabled: true)
        let anchor = AppLockCoverAnchorView(controller: fixture.controller, isInteractive: true)
        host.addSubview(anchor)

        anchor.setCovered(true)
        let cover = try #require(anchor.debugCoverWindow)
        #expect(!cover.isHidden)
        #expect(cover.windowLevel > UIWindow.Level.alert)
        #expect(cover.isKeyWindow)

        anchor.setCovered(false)
        #expect(cover.isHidden)
        #expect(host.isKeyWindow)
        anchor.removeCover()
        host.isHidden = true
    }

    @MainActor
    private final class Fixture {
        let defaults: UserDefaults
        let controller: AppLockController
        private let box: ResultBox
        private var current = Date(timeIntervalSince1970: 1_000)

        var reasons: [String] { box.reasons }

        init(results: [AppLockController.AuthenticationResult] = [],
             method: AppLockController.Method? = .faceID,
             enabled: Bool = false,
             delay: AppLockController.RelockDelay = .immediately) throws {
            let suiteName = "AppLockControllerTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.set(enabled, forKey: AppLockController.isEnabledKey)
            defaults.set(delay.rawValue, forKey: AppLockController.relockDelayKey)
            let box = ResultBox(results)
            self.box = box
            var clock: (() -> Date)!
            controller = AppLockController(
                defaults: defaults,
                authenticator: .init(availableMethod: { method },
                                     authenticate: { reason in box.next(reason) }),
                now: { clock() }
            )
            clock = { [unowned self] in current }
        }

        func advance(by seconds: TimeInterval) {
            current = current.addingTimeInterval(seconds)
        }

        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !condition() {
                try #require(ContinuousClock.now < deadline, "Timed out waiting for the lock")
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [AppLockController.AuthenticationResult]
        private var receivedReasons: [String] = []

        init(_ results: [AppLockController.AuthenticationResult]) { self.results = results }

        var reasons: [String] { lock.withLock { receivedReasons } }

        func next(_ reason: String) -> AppLockController.AuthenticationResult {
            lock.withLock {
                receivedReasons.append(reason)
                return results.isEmpty ? .cancelled : results.removeFirst()
            }
        }
    }
}
