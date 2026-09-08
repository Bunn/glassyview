import Foundation
import Observation

struct FreeSessionCooldown: Equatable {
    static let duration: TimeInterval = 30

    let endDate: Date

    func remainingSeconds(at date: Date) -> Int {
        max(0, min(Int(Self.duration), Int(ceil(endDate.timeIntervalSince(date)))))
    }

    func progress(at date: Date) -> Double {
        min(1, max(0, 1 - endDate.timeIntervalSince(date) / Self.duration))
    }
}

/// Keeps the free-session deadline separate from the wait for the next session.
/// Only the cooldown persists, so leaving the screen does not restart the wait.
@MainActor
@Observable
final class FreeSessionLifecycle {
    static let sessionDuration: TimeInterval = 60
    private static let cooldownStorageKey = "freeSession.cooldownEndDate"

    private(set) var sessionEndDate: Date?
    private(set) var cooldown: FreeSessionCooldown?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, now: Date = .now) {
        self.defaults = defaults
        if let endDate = defaults.object(forKey: Self.cooldownStorageKey) as? Date,
           endDate > now {
            cooldown = FreeSessionCooldown(endDate: endDate)
        }
    }

    @discardableResult
    func startIfNeeded(at date: Date = .now) -> Bool {
        guard sessionEndDate == nil, cooldown == nil else { return false }
        sessionEndDate = date.addingTimeInterval(Self.sessionDuration)
        return true
    }

    @discardableResult
    func endIfNeeded(at date: Date = .now) -> Bool {
        guard let sessionEndDate, sessionEndDate <= date, cooldown == nil else { return false }

        // Use the original deadline so backgrounding or viewing the paywall
        // does not add extra time to the wait.
        let endDate = sessionEndDate.addingTimeInterval(FreeSessionCooldown.duration)
        cooldown = FreeSessionCooldown(endDate: endDate)
        self.sessionEndDate = nil
        defaults.set(endDate, forKey: Self.cooldownStorageKey)
        return true
    }

    func resetActiveSession() {
        sessionEndDate = nil
    }

    @discardableResult
    func prepareNextSession(at date: Date = .now) -> Bool {
        guard let cooldown, cooldown.endDate <= date else { return false }
        clearLimits()
        return true
    }

    func clearLimits() {
        sessionEndDate = nil
        cooldown = nil
        defaults.removeObject(forKey: Self.cooldownStorageKey)
    }
}
