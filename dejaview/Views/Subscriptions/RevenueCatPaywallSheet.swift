import RevenueCat
import RevenueCatUI
import SwiftUI

struct RevenueCatPaywallSheet: View {
    @Environment(SubscriptionStore.self) private var subscriptionStore
    @Environment(\.analyticsTracker) private var analytics
    @Environment(\.funnelMilestoneTracker) private var funnelMilestones

    @State private var didRecordPresentation = false
    @State private var didRecordDismissal = false
    @State private var didGrantProAccess = false

    private let source: PaywallSource
    private let onProAccessGranted: (@MainActor @Sendable () -> Void)?

    init(
        source: PaywallSource = .settings,
        onProAccessGranted: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.source = source
        self.onProAccessGranted = onProAccessGranted
    }

    var body: some View {
        Group {
            if Purchases.isConfigured {
                PaywallView()
                    // Match the compact layout configured in RevenueCat's phone preview.
                    .environment(\.horizontalSizeClass, .compact)
                    .onPurchaseStarted { _ in
                        recordPurchaseStarted()
                    }
                    .onPurchaseCompleted { customerInfo in
                        handlePurchaseCompleted(customerInfo)
                    }
                    .onPurchaseCancelled {
                        recordPurchaseCancelled()
                    }
                    .onPurchaseFailure { error in
                        recordPurchaseFailure(error)
                    }
                    .onRestoreStarted {
                        analytics.track(
                            .restoreStarted,
                            context: AnalyticsEventContext(source: source.analyticsSource)
                        )
                    }
                    .onRestoreCompleted { customerInfo in
                        handleRestoreCompleted(customerInfo)
                    }
                    .onRestoreFailure { error in
                        analytics.track(
                            .restoreFailed,
                            context: AnalyticsEventContext(
                                source: source.analyticsSource,
                                outcome: .failure,
                                reason: analyticsReason(for: error)
                            )
                        )
                    }
                    .task {
                        await subscriptionStore.refresh()
                    }
            } else {
                RevenueCatUnavailableView()
            }
        }
        // The default iPad form sheet is too short for this full-height paywall.
        .presentationSizing(.page)
        .task {
            recordPresentationIfNeeded()
        }
        .onDisappear {
            recordDismissalIfNeeded()
        }
    }

    private func handlePurchaseCompleted(_ customerInfo: CustomerInfo) {
        subscriptionStore.apply(customerInfo)

        if subscriptionStore.hasProAccess {
            didGrantProAccess = true
            funnelMilestones.record(.purchaseCompleted)
            analytics.track(
                .purchaseCompleted,
                context: AnalyticsEventContext(
                    source: source.analyticsSource,
                    outcome: .success
                )
            )
            onProAccessGranted?()
        } else {
            analytics.track(
                .purchaseCompleted,
                context: AnalyticsEventContext(
                    source: source.analyticsSource,
                    outcome: .unavailable,
                    reason: .configuration
                )
            )
        }
    }

    private func handleRestoreCompleted(_ customerInfo: CustomerInfo) {
        subscriptionStore.apply(customerInfo)
        let restoredProAccess = subscriptionStore.hasProAccess
        didGrantProAccess = restoredProAccess
        analytics.track(
            .restoreCompleted,
            context: AnalyticsEventContext(
                source: source.analyticsSource,
                outcome: restoredProAccess ? .success : .unavailable
            )
        )

        if restoredProAccess {
            onProAccessGranted?()
        }
    }

    private func recordPresentationIfNeeded() {
        guard !didRecordPresentation else { return }
        didRecordPresentation = true

        funnelMilestones.record(source.funnelMilestone)
        analytics.track(
            .paywallPresented,
            context: AnalyticsEventContext(source: source.analyticsSource)
        )
    }

    private func recordDismissalIfNeeded() {
        guard !didRecordDismissal, !didGrantProAccess else { return }
        didRecordDismissal = true

        analytics.track(
            .paywallDismissed,
            context: AnalyticsEventContext(
                source: source.analyticsSource,
                outcome: .cancelled
            )
        )
    }

    private func recordPurchaseStarted() {
        funnelMilestones.record(.purchaseStarted)
        analytics.track(
            .purchaseStarted,
            context: AnalyticsEventContext(source: source.analyticsSource)
        )
    }

    private func recordPurchaseCancelled() {
        funnelMilestones.record(.purchaseCancelled)
        analytics.track(
            .purchaseCancelled,
            context: AnalyticsEventContext(
                source: source.analyticsSource,
                outcome: .cancelled
            )
        )
    }

    private func recordPurchaseFailure(_ error: NSError) {
        funnelMilestones.record(.purchaseFailed)
        analytics.track(
            .purchaseFailed,
            context: AnalyticsEventContext(
                source: source.analyticsSource,
                outcome: .failure,
                reason: analyticsReason(for: error)
            )
        )
    }

    private func analyticsReason(for error: NSError) -> AnalyticsEventReason {
        guard let errorCode = ErrorCode(rawValue: error.code) else { return .unknown }

        return switch errorCode {
        case .networkError,
             .offlineConnectionError,
             .apiEndpointBlockedError,
             .productRequestTimedOut:
            .network
        case .storeProblemError,
             .productNotAvailableForPurchaseError:
            .storeUnavailable
        case .purchaseNotAllowedError,
             .insufficientPermissionsError,
             .ineligibleError:
            .purchaseNotAllowed
        case .paymentPendingError:
            .paymentPending
        case .configurationError,
             .invalidCredentialsError,
             .invalidAppleSubscriptionKeyError:
            .configuration
        default:
            .unknown
        }
    }
}
