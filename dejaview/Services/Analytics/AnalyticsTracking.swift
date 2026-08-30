import Foundation
import SwiftUI

enum AnalyticsPreference {
    static let collectionEnabledKey = "privacyPreservingAnalyticsEnabled"
    static let defaultCollectionEnabled = true
}

enum AnalyticsEventName: String, Codable, Sendable {
    case appOpened = "app_opened"
    case analyticsDisabled = "analytics_disabled"
    case onboardingCompleted = "onboarding_completed"
    case remoteSessionConnected = "remote_session_connected"
    case freeSessionStarted = "free_session_started"
    case freeSessionRestarted = "free_session_restarted"
    case freeSessionRestartedAfterLimit = "free_session_restarted_after_limit"
    case freeSessionTimerOpened = "free_session_timer_opened"
    case freeSessionLimitReached = "free_session_limit_reached"
    case paywallPresented = "paywall_presented"
    case paywallDismissed = "paywall_dismissed"
    case purchaseStarted = "purchase_started"
    case purchaseCompleted = "purchase_completed"
    case purchaseCancelled = "purchase_cancelled"
    case purchaseFailed = "purchase_failed"
    case restoreStarted = "restore_started"
    case restoreCompleted = "restore_completed"
    case restoreFailed = "restore_failed"
}

enum AnalyticsEventSource: String, Codable, Sendable {
    case app
    case onboarding
    case settings
    case freeSessionTimer = "free_session_timer"
    case sessionLimit = "session_limit"
    case unknown
}

enum AnalyticsEventOutcome: String, Codable, Sendable {
    case success
    case failure
    case cancelled
    case unavailable
}

enum AnalyticsEventReason: String, Codable, Sendable {
    case network
    case storeUnavailable = "store_unavailable"
    case purchaseNotAllowed = "purchase_not_allowed"
    case paymentPending = "payment_pending"
    case configuration
    case unknown
}

enum AnalyticsDeviceClass: String, Codable, Sendable {
    case iPhone = "iphone"
    case iPad = "ipad"
    case other

    init(interfaceIdiom: UIUserInterfaceIdiom) {
        switch interfaceIdiom {
        case .phone:
            self = .iPhone
        case .pad:
            self = .iPad
        default:
            self = .other
        }
    }
}

enum PaywallSource: String, CaseIterable, Sendable {
    case settings
    case freeSessionTimer = "free_session_timer"
    case sessionLimit = "session_limit"

    var analyticsSource: AnalyticsEventSource {
        switch self {
        case .settings:
            .settings
        case .freeSessionTimer:
            .freeSessionTimer
        case .sessionLimit:
            .sessionLimit
        }
    }
}

struct AnalyticsEventContext: Codable, Equatable, Sendable {
    let source: AnalyticsEventSource?
    let outcome: AnalyticsEventOutcome?
    let reason: AnalyticsEventReason?

    init(
        source: AnalyticsEventSource? = nil,
        outcome: AnalyticsEventOutcome? = nil,
        reason: AnalyticsEventReason? = nil
    ) {
        self.source = source
        self.outcome = outcome
        self.reason = reason
    }
}

struct AnalyticsEvent: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let event: AnalyticsEventName
    let app: String
    let platform: String
    let deviceClass: AnalyticsDeviceClass
    let appVersion: String
    let build: String
    let osMajor: Int
    let context: AnalyticsEventContext?

    init(
        name: AnalyticsEventName,
        context: AnalyticsEventContext?,
        metadata: AnalyticsAppMetadata
    ) {
        schemaVersion = 1
        event = name
        app = "glassydesk"
        platform = metadata.platform
        deviceClass = metadata.deviceClass
        appVersion = metadata.appVersion
        build = metadata.build
        osMajor = metadata.osMajor
        self.context = context
    }
}

struct AnalyticsBatch: Codable, Equatable, Sendable {
    let events: [AnalyticsEvent]
}

struct AnalyticsAppMetadata: Equatable, Sendable {
    let platform: String
    let deviceClass: AnalyticsDeviceClass
    let appVersion: String
    let build: String
    let osMajor: Int

    @MainActor
    static var current: AnalyticsAppMetadata {
        AnalyticsAppMetadata(
            platform: "ios",
            deviceClass: AnalyticsDeviceClass(
                interfaceIdiom: UIDevice.current.userInterfaceIdiom
            ),
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0",
            build: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "0",
            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }
}

@MainActor
protocol AnalyticsTracking: Sendable {
    func setCollectionEnabled(_ enabled: Bool)
    func disableCollectionAfterTrackingOptOut() async
    func track(_ event: AnalyticsEventName, context: AnalyticsEventContext?)
    func flush()
}

extension AnalyticsTracking {
    func track(_ event: AnalyticsEventName) {
        track(event, context: nil)
    }
}

@MainActor
struct NoOpAnalyticsTracker: AnalyticsTracking {
    func setCollectionEnabled(_ enabled: Bool) {}
    func disableCollectionAfterTrackingOptOut() async {}
    func track(_ event: AnalyticsEventName, context: AnalyticsEventContext?) {}
    func flush() {}
}

private struct AnalyticsTrackerKey: EnvironmentKey {
    static let defaultValue: any AnalyticsTracking = NoOpAnalyticsTracker()
}

extension EnvironmentValues {
    var analyticsTracker: any AnalyticsTracking {
        get { self[AnalyticsTrackerKey.self] }
        set { self[AnalyticsTrackerKey.self] = newValue }
    }
}

nonisolated enum AnalyticsRuntime {
    static var isUnitTestHost: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    static var isUITestingLaunch: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--uitesting")
        #else
        false
        #endif
    }

    static var shouldRunProductionAnalytics: Bool {
        !isUnitTestHost && !isUITestingLaunch
    }
}
