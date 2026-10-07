import Foundation
import LocalAuthentication
import Observation
import OSLog

/// Optional Face ID, Touch ID, Optic ID, or passcode lock for the whole app.
///
/// When enabled, Glassy Desk starts locked and locks again after spending
/// longer than the chosen delay in the background. While the app is inactive
/// or in the background, its windows are covered so the app switcher never
/// shows a remote screen. Sessions keep running underneath the lock; nothing
/// is visible or controllable until the person authenticates.
@MainActor
@Observable
final class AppLockController {
    static let shared = AppLockController()

    nonisolated static let isEnabledKey = "appLock.isEnabled"
    nonisolated static let relockDelayKey = "appLock.relockDelay"

    enum RelockDelay: Int, CaseIterable, Identifiable, Sendable {
        case immediately = 0
        case oneMinute = 60
        case fiveMinutes = 300
        case fifteenMinutes = 900

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .immediately: String(localized: "Immediately")
            case .oneMinute: String(localized: "After 1 Minute")
            case .fiveMinutes: String(localized: "After 5 Minutes")
            case .fifteenMinutes: String(localized: "After 15 Minutes")
            }
        }
    }

    enum Method: Equatable, Sendable {
        case faceID, touchID, opticID, passcode

        var title: String {
            switch self {
            case .faceID: String(localized: "Face ID")
            case .touchID: String(localized: "Touch ID")
            case .opticID: String(localized: "Optic ID")
            case .passcode: String(localized: "Passcode")
            }
        }

        var systemImage: String {
            switch self {
            case .faceID: "faceid"
            case .touchID: "touchid"
            case .opticID: "opticid"
            case .passcode: "lock.fill"
            }
        }
    }

    enum AuthenticationResult: Equatable, Sendable {
        case success
        case cancelled
        case failed(String)
    }

    /// Evaluates device-owner authentication: biometrics with a passcode fallback.
    struct Authenticator: Sendable {
        var availableMethod: @Sendable () -> Method?
        var authenticate: @Sendable (_ reason: String) async -> AuthenticationResult

        static let live = Authenticator(
            availableMethod: {
                let context = LAContext()
                guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return nil }
                switch context.biometryType {
                case .faceID: return .faceID
                case .touchID: return .touchID
                case .opticID: return .opticID
                default: return .passcode
                }
            },
            authenticate: { reason in
                let context = LAContext()
                context.localizedCancelTitle = String(localized: "Cancel")
                do {
                    try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                    return .success
                } catch let error as LAError {
                    switch error.code {
                    case .userCancel, .appCancel, .systemCancel:
                        return .cancelled
                    default:
                        return .failed(error.localizedDescription)
                    }
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
        )
    }

    private(set) var isEnabled: Bool
    private(set) var relockDelay: RelockDelay
    /// Content stays hidden until authentication succeeds.
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    private(set) var errorMessage: String?
    /// The app is inactive or in the background; hide content from snapshots.
    private(set) var isObscured = false

    /// Whether any window should show the cover.
    var showsCover: Bool {
        isEnabled && (isLocked || isObscured)
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let authenticator: Authenticator
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var backgroundedAt: Date?

    init(defaults: UserDefaults = .standard,
         authenticator: Authenticator = .live,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.authenticator = authenticator
        self.now = now
        let isEnabled = defaults.bool(forKey: Self.isEnabledKey)
        self.isEnabled = isEnabled
        relockDelay = RelockDelay(rawValue: defaults.integer(forKey: Self.relockDelayKey)) ?? .immediately
        isLocked = isEnabled
    }

    var availableMethod: Method? {
        authenticator.availableMethod()
    }

    // MARK: - Settings

    /// Turning the lock on or off requires authentication, so someone holding
    /// an unlocked device cannot quietly remove it.
    @discardableResult
    func setEnabled(_ enabled: Bool) async -> Bool {
        guard enabled != isEnabled else { return true }
        guard availableMethod != nil else {
            errorMessage = String(localized: "Set a passcode for this device in Settings to lock Glassy Desk.")
            return false
        }
        let reason = enabled
            ? String(localized: "Require authentication to open Glassy Desk.")
            : String(localized: "Stop requiring authentication to open Glassy Desk.")
        guard await runAuthentication(reason: reason) else { return false }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.isEnabledKey)
        isLocked = false
        AppLog.app.info("App lock enabled=\(enabled, privacy: .public)")
        return true
    }

    func setRelockDelay(_ delay: RelockDelay) {
        relockDelay = delay
        defaults.set(delay.rawValue, forKey: Self.relockDelayKey)
    }

    // MARK: - Lifecycle

    func sceneBecameInactive() {
        isObscured = true
    }

    func sceneEnteredBackground() {
        isObscured = true
        if backgroundedAt == nil { backgroundedAt = now() }
    }

    /// Locks when the app was away longer than the delay, then asks to unlock.
    func sceneBecameActive() {
        isObscured = false
        defer { backgroundedAt = nil }
        guard isEnabled else { return }
        if let backgroundedAt, now().timeIntervalSince(backgroundedAt) >= TimeInterval(relockDelay.rawValue) {
            isLocked = true
        }
        if isLocked, !isAuthenticating {
            Task { await unlock() }
        }
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        if await runAuthentication(reason: String(localized: "Unlock Glassy Desk to see and control your Macs.")) {
            isLocked = false
        }
    }

    private func runAuthentication(reason: String) async -> Bool {
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }
        switch await authenticator.authenticate(reason) {
        case .success:
            return true
        case .cancelled:
            return false
        case let .failed(message):
            errorMessage = message
            AppLog.app.info("App lock authentication failed")
            return false
        }
    }
}
