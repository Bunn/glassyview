import Foundation
import Observation

@MainActor
@Observable
final class HostPermissionController {
    private(set) var snapshot: HostPermissionSnapshot?
    private(set) var isRefreshing = false
    private(set) var isConfirmingScreenAccess = false
    private(set) var hasConfirmedDirectScreenAccess: Bool
    private(set) var errorMessage: String?

    @ObservationIgnored private let readStatus: @MainActor () async throws -> HostPermissionSnapshot
    @ObservationIgnored private let requestDirectAccess: @MainActor () async throws -> [CaptureDisplay]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var refreshTask: Task<Bool, Never>?
    @ObservationIgnored private var needsAnotherRefresh = false
    @ObservationIgnored private var authorizationGeneration = 0

    static let confirmationKey = "host.permissions.directScreenAccessConfirmed"

    init(
        defaults: UserDefaults = .standard,
        readStatus: @escaping @MainActor () async throws -> HostPermissionSnapshot = {
            try await HostPermissionStatusProbe.freshSnapshot()
        },
        requestDirectAccess: @escaping @MainActor () async throws -> [CaptureDisplay] = {
            try await ScreenCaptureService.confirmDirectScreenAccess()
        }
    ) {
        self.defaults = defaults
        self.readStatus = readStatus
        self.requestDirectAccess = requestDirectAccess
        hasConfirmedDirectScreenAccess = defaults.bool(forKey: Self.confirmationKey)
    }

    var screenRecordingAuthorization: ScreenRecordingAuthorization {
        guard let snapshot else { return .unknown }
        return snapshot.screenRecording ? .granted : .denied
    }

    var accessibilityAuthorization: AccessibilityAuthorization {
        guard let snapshot else { return .unknown }
        return snapshot.accessibility ? .granted : .denied
    }

    var canCaptureScreen: Bool {
        snapshot?.screenRecording == true && hasConfirmedDirectScreenAccess
    }

    /// Passive checks never call ScreenCaptureKit: doing so can itself present
    /// the direct-access consent dialog. Coalesce focus notifications, including
    /// a trailing check if Settings changed while a previous check was running.
    @discardableResult
    func refresh() async -> Bool {
        if let refreshTask {
            needsAnotherRefresh = true
            _ = await refreshTask.value
            return false
        }
        isRefreshing = true
        let task = Task { @MainActor in
            defer {
                refreshTask = nil
                isRefreshing = false
            }
            let previousSnapshot = snapshot
            repeat {
                needsAnotherRefresh = false
                do {
                    let fresh = try await readStatus()
                    snapshot = fresh
                    if !fresh.screenRecording {
                        invalidateDirectScreenAccess()
                    }
                    if !isConfirmingScreenAccess { errorMessage = nil }
                } catch {
                    snapshot = nil
                    errorMessage = "Couldn’t check permissions. Choose Check Again to retry."
                }
            } while needsAnotherRefresh
            return snapshot != previousSnapshot
        }
        refreshTask = task
        return await task.value
    }

    /// Only an explicit local setup action may request this extra macOS
    /// approval. Completion records a successful capture check, not a substitute
    /// for the system's authorization, which is still enforced on every stream.
    func confirmDirectScreenAccess() async -> [CaptureDisplay]? {
        guard !isConfirmingScreenAccess else { return nil }
        isConfirmingScreenAccess = true
        defer { isConfirmingScreenAccess = false }
        await refresh()
        guard snapshot?.screenRecording == true else {
            errorMessage = "Enable Screen Recording in System Settings first, then return here."
            return nil
        }
        errorMessage = nil
        let generation = authorizationGeneration
        do {
            let displays = try await requestDirectAccess()
            guard !displays.isEmpty else { throw ScreenCaptureServiceError.noDisplaysAvailable }
            guard generation == authorizationGeneration, snapshot?.screenRecording == true else {
                errorMessage = "Screen Recording access changed. Enable it, then confirm screen access again."
                return nil
            }
            hasConfirmedDirectScreenAccess = true
            defaults.set(true, forKey: Self.confirmationKey)
            return displays
        } catch {
            invalidateDirectScreenAccess()
            errorMessage = "Screen access wasn’t confirmed. Choose Confirm… and allow access in the macOS dialog. If macOS requires a relaunch, reopen Glassy Desk and try again."
            return nil
        }
    }

    func invalidateDirectScreenAccess() {
        authorizationGeneration &+= 1
        hasConfirmedDirectScreenAccess = false
        defaults.removeObject(forKey: Self.confirmationKey)
    }
}
