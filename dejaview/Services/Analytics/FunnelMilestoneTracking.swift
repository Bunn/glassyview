import Foundation
import RevenueCat
import SwiftUI

nonisolated enum FunnelMilestone: CaseIterable, Equatable, Sendable {
    case onboardingCompleted
    case firstRemoteSessionConnected
    case firstFreeSessionStarted
    case freeSessionRestarted
    case freeSessionRestartedAfterLimit
    case freeSessionLimitReached
    case freeTimerUpgradeTapped
    case paywallSettingsPresented
    case paywallFreeTimerPresented
    case paywallSessionLimitPresented
    case purchaseStarted
    case purchaseCompleted
    case purchaseCancelled
    case purchaseFailed

    var revenueCatAttributeKey: String {
        switch self {
        case .onboardingCompleted:
            "gv_ms_onboarding_completed"
        case .firstRemoteSessionConnected:
            "gv_ms_first_session_connected"
        case .firstFreeSessionStarted:
            "gv_ms_first_free_session"
        case .freeSessionRestarted:
            "gv_ms_free_session_restarted"
        case .freeSessionRestartedAfterLimit:
            "gv_ms_refresh_after_limit"
        case .freeSessionLimitReached:
            "gv_ms_free_limit_reached"
        case .freeTimerUpgradeTapped:
            "gv_ms_free_timer_upgrade_tapped"
        case .paywallSettingsPresented:
            "gv_ms_paywall_settings"
        case .paywallFreeTimerPresented:
            "gv_ms_paywall_free_timer"
        case .paywallSessionLimitPresented:
            "gv_ms_paywall_session_limit"
        case .purchaseStarted:
            "gv_ms_purchase_started"
        case .purchaseCompleted:
            "gv_ms_purchase_completed"
        case .purchaseCancelled:
            "gv_ms_purchase_cancelled"
        case .purchaseFailed:
            "gv_ms_purchase_failed"
        }
    }
}

extension PaywallSource {
    var funnelMilestone: FunnelMilestone {
        switch self {
        case .settings:
            .paywallSettingsPresented
        case .freeSessionTimer:
            .paywallFreeTimerPresented
        case .sessionLimit:
            .paywallSessionLimitPresented
        }
    }
}

enum FreeSessionStartKind: Equatable, Sendable {
    case first
    case returning
    case restartedAfterLimit
}

enum FreeSessionUsageBand: String, Equatable, Sendable {
    case one = "1"
    case two = "2"
    case threeToFive = "3_5"
    case sixToTen = "6_10"
    case elevenPlus = "11_plus"

    init(sessionCount: Int) {
        switch sessionCount {
        case ...1:
            self = .one
        case 2:
            self = .two
        case 3...5:
            self = .threeToFive
        case 6...10:
            self = .sixToTen
        default:
            self = .elevenPlus
        }
    }
}

@MainActor
protocol FunnelMilestoneTracking: Sendable {
    func setCollectionEnabled(_ enabled: Bool)
    func record(_ milestone: FunnelMilestone)
    func recordFreeSessionStarted() -> FreeSessionStartKind
    func recordFreeSessionLimitReached()
}

@MainActor
protocol RevenueCatAttributeWriting {
    var isConfigured: Bool { get }
    func setAttributes(_ attributes: [String: String])
}

@MainActor
struct LiveRevenueCatAttributeWriter: RevenueCatAttributeWriting {
    var isConfigured: Bool {
        Purchases.isConfigured
    }

    func setAttributes(_ attributes: [String: String]) {
        Purchases.shared.attribution.setAttributes(attributes)
    }
}

#if DEBUG
@MainActor
struct DebugConsoleRevenueCatAttributeWriter: RevenueCatAttributeWriting {
    typealias AttributeLogger = @MainActor @Sendable ([String: String]) -> Void

    let isConfigured = true
    private let logAttributes: AttributeLogger

    init(
        logAttributes: @escaping AttributeLogger =
            DebugConsoleRevenueCatAttributeWriter.logToConsole
    ) {
        self.logAttributes = logAttributes
    }

    func setAttributes(_ attributes: [String: String]) {
        logAttributes(attributes)
    }

    private static func logToConsole(_ attributes: [String: String]) {
        let fields = attributes
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        AppLog.analytics.info(
            "Debug analytics funnel attributes; values=\(fields, privacy: .public) sent=false"
        )
    }
}
#endif

@MainActor
final class RevenueCatFunnelMilestoneTracker: FunnelMilestoneTracking {
    private enum StorageKey {
        static let freeSessionCount = "analytics.freeSessionCount"
        static let freeSessionBand = "analytics.freeSessionBand"
        static let previousSessionReachedLimit = "analytics.previousFreeSessionReachedLimit"
        static let revenueCatBand = "gv_free_session_band"
    }

    private let revenueCat: any RevenueCatAttributeWriting
    private let defaults: UserDefaults
    private let productionAnalyticsEnabled: () -> Bool
    private var isCollectionEnabled = false

    init(
        revenueCat: (any RevenueCatAttributeWriting)? = nil,
        defaults: UserDefaults = .standard,
        productionAnalyticsEnabled: @escaping () -> Bool = {
            AnalyticsRuntime.shouldRunProductionAnalytics
        }
    ) {
        self.revenueCat = revenueCat ?? LiveRevenueCatAttributeWriter()
        self.defaults = defaults
        self.productionAnalyticsEnabled = productionAnalyticsEnabled
    }

    func setCollectionEnabled(_ enabled: Bool) {
        isCollectionEnabled = enabled

        guard !enabled else { return }
        FunnelMilestone.allCases.forEach {
            defaults.removeObject(forKey: persistenceKey(for: $0))
        }
        defaults.removeObject(forKey: StorageKey.freeSessionCount)
        defaults.removeObject(forKey: StorageKey.freeSessionBand)
        defaults.removeObject(forKey: StorageKey.previousSessionReachedLimit)
    }

    func record(_ milestone: FunnelMilestone) {
        guard canRecordToRevenueCat else { return }

        let key = persistenceKey(for: milestone)
        guard !defaults.bool(forKey: key) else { return }

        revenueCat.setAttributes([milestone.revenueCatAttributeKey: "1"])
        defaults.set(true, forKey: key)
    }

    func recordFreeSessionStarted() -> FreeSessionStartKind {
        guard canCollect else { return .first }

        let previousSessionReachedLimit = defaults.bool(
            forKey: StorageKey.previousSessionReachedLimit
        )
        let sessionCount = defaults.integer(forKey: StorageKey.freeSessionCount) + 1
        let kind: FreeSessionStartKind

        if sessionCount == 1 {
            kind = .first
        } else if previousSessionReachedLimit {
            kind = .restartedAfterLimit
        } else {
            kind = .returning
        }

        defaults.set(sessionCount, forKey: StorageKey.freeSessionCount)
        defaults.set(false, forKey: StorageKey.previousSessionReachedLimit)

        if sessionCount == 1 {
            record(.firstFreeSessionStarted)
        } else {
            record(.freeSessionRestarted)
            if previousSessionReachedLimit {
                record(.freeSessionRestartedAfterLimit)
            }
        }

        let band = FreeSessionUsageBand(sessionCount: sessionCount)
        if revenueCat.isConfigured,
           defaults.string(forKey: StorageKey.freeSessionBand) != band.rawValue {
            revenueCat.setAttributes([StorageKey.revenueCatBand: band.rawValue])
            defaults.set(band.rawValue, forKey: StorageKey.freeSessionBand)
        }

        return kind
    }

    func recordFreeSessionLimitReached() {
        guard canCollect else { return }

        defaults.set(true, forKey: StorageKey.previousSessionReachedLimit)
        record(.freeSessionLimitReached)
    }

    private var canCollect: Bool {
        isCollectionEnabled && productionAnalyticsEnabled()
    }

    private var canRecordToRevenueCat: Bool {
        canCollect && revenueCat.isConfigured
    }

    private func persistenceKey(for milestone: FunnelMilestone) -> String {
        "analytics.revenuecat.\(milestone.revenueCatAttributeKey)"
    }

    #if DEBUG
    static func consoleOnly() -> RevenueCatFunnelMilestoneTracker {
        let suiteName = "dev.bunn.glassydesk.debug-analytics"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create Debug analytics defaults")
        }

        return RevenueCatFunnelMilestoneTracker(
            revenueCat: DebugConsoleRevenueCatAttributeWriter(),
            defaults: defaults,
            productionAnalyticsEnabled: { true }
        )
    }
    #endif
}

@MainActor
struct NoOpFunnelMilestoneTracker: FunnelMilestoneTracking {
    func setCollectionEnabled(_ enabled: Bool) {}
    func record(_ milestone: FunnelMilestone) {}
    func recordFreeSessionStarted() -> FreeSessionStartKind { .first }
    func recordFreeSessionLimitReached() {}
}

private struct FunnelMilestoneTrackerKey: EnvironmentKey {
    static let defaultValue: any FunnelMilestoneTracking = NoOpFunnelMilestoneTracker()
}

extension EnvironmentValues {
    var funnelMilestoneTracker: any FunnelMilestoneTracking {
        get { self[FunnelMilestoneTrackerKey.self] }
        set { self[FunnelMilestoneTrackerKey.self] = newValue }
    }
}
