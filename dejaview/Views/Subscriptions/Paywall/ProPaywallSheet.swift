import RevenueCat
import SwiftUI

/// Glassy Desk's own paywall. RevenueCat supplies the offering, prices, purchases,
/// and entitlements; everything on screen is drawn here.
struct ProPaywallSheet: View {
    @Environment(SubscriptionStore.self) private var subscriptionStore
    @Environment(\.analyticsTracker) private var analytics
    @Environment(\.funnelMilestoneTracker) private var funnelMilestones
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selection = PaywallPlan.Kind.yearly
    @State private var hasAppeared = false
    @State private var isCelebrating = false
    @State private var offeringsTimedOut = false
    @State private var availableHeight: CGFloat = 900
    @State private var alert: PaywallAlert?
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
        ZStack {
            if Purchases.isConfigured {
                paywall
            } else {
                RevenueCatUnavailableView()
            }

            if isCelebrating {
                PaywallCelebration(doneTitle: source == .settings ? "Done" : "Back to Your Mac",
                                   done: dismiss.callAsFunction)
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
                    .zIndex(1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !isCelebrating {
                Button("Close", systemImage: "xmark", action: dismiss.callAsFunction)
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .padding(12)
                    .disabled(subscriptionStore.isPurchasing)
                    .accessibilityIdentifier("subscription.paywall.close")
                    .transition(.opacity)
            }
        }
        // The default iPad form sheet is too short for this full-height paywall.
        .presentationSizing(.page)
        .interactiveDismissDisabled(subscriptionStore.isPurchasing)
        .alert(alert?.title ?? "", isPresented: isAlertPresented, presenting: alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .onChange(of: subscriptionStore.hasProAccess) { _, hasProAccess in
            if hasProAccess {
                celebrateProAccess()
            }
        }
        .task(id: isCelebrating) {
            // Return on its own if the celebration is left alone.
            guard isCelebrating, (try? await Task.sleep(for: .seconds(6))) != nil else { return }
            dismiss()
        }
        .task {
            recordPresentationIfNeeded()
        }
        .onDisappear {
            recordDismissalIfNeeded()
        }
    }

    private var paywall: some View {
        let plans = PaywallPlan.plans(in: subscriptionStore.currentOffering,
                                      introOfferEligibleProductIDs: subscriptionStore.introOfferEligibleProductIDs)
        let selectedPlan = plans.first { $0.kind == selection } ?? plans.first

        return ZStack {
            PaywallBackdrop(animates: animates)

            ScrollView {
                VStack(spacing: 18) {
                    PaywallHero(animates: animates, scale: heroScale)
                        .padding(.top, 8)

                    PaywallHeadline(source: source)
                        .paywallEntrance(1, isVisible: hasAppeared)

                    PaywallFeatureList(isVisible: hasAppeared, animates: animates)
                        .paywallEntrance(2, isVisible: hasAppeared)

                    PaywallPlanPicker(plans: plans,
                                      selection: $selection,
                                      loadFailed: offeringsUnavailable,
                                      retry: reloadOfferings)
                        .paywallEntrance(7, isVisible: hasAppeared)

                    PaywallFinePrint()
                        .paywallEntrance(8, isVisible: hasAppeared)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PaywallPurchaseBar(plan: selectedPlan,
                                   isPurchasing: subscriptionStore.isPurchasing,
                                   isRestoring: subscriptionStore.isRestoring,
                                   animates: animates,
                                   purchase: { if let selectedPlan { purchase(selectedPlan) } },
                                   restore: restore)
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    .background {
                        Rectangle()
                            .fill(.regularMaterial)
                            .mask {
                                LinearGradient(stops: [.init(color: .clear, location: 0),
                                                       .init(color: .black, location: 0.16)],
                                               startPoint: .top, endPoint: .bottom)
                            }
                            .ignoresSafeArea()
                    }
                    .paywallEntrance(4, isVisible: hasAppeared)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            availableHeight = height
        }
        .onAppear {
            hasAppeared = true
        }
        .task {
            await subscriptionStore.refresh()
        }
        .task(id: offeringsTimedOut) {
            // Don't leave placeholders up forever when the store never answers.
            guard !offeringsTimedOut, (try? await Task.sleep(for: .seconds(10))) != nil else { return }
            offeringsTimedOut = subscriptionStore.currentOffering == nil
        }
    }

    /// Shrinks the hero on shorter screens so the plans stay above the purchase bar.
    private var heroScale: CGFloat {
        min(1, max(0.6, (availableHeight - 660) / 260))
    }

    private var offeringsUnavailable: Bool {
        subscriptionStore.currentOffering == nil && (offeringsTimedOut || !subscriptionStore.isRefreshing)
    }

    private var animates: Bool {
        !reduceMotion && scenePhase == .active && !isCelebrating
    }

    private var isAlertPresented: Binding<Bool> {
        Binding {
            alert != nil
        } set: { isPresented in
            if !isPresented { alert = nil }
        }
    }

    private func reloadOfferings() {
        offeringsTimedOut = false
        Task { await subscriptionStore.reloadOfferings() }
    }

    private func purchase(_ plan: PaywallPlan) {
        recordPurchaseStarted()

        Task {
            switch await subscriptionStore.purchaseOutcome(for: plan.package) {
            case .purchased:
                handlePurchaseCompleted()
            case .cancelled:
                recordPurchaseCancelled()
            case .failed(let error):
                recordPurchaseFailure(error)
                alert = ErrorCode(rawValue: error.code) == .paymentPendingError
                    ? .paymentPending
                    : .purchaseFailed(error.localizedDescription)
            }
        }
    }

    private func restore() {
        analytics.track(
            .restoreStarted,
            context: AnalyticsEventContext(source: source.analyticsSource)
        )

        Task {
            switch await subscriptionStore.restoreOutcome() {
            case .restored:
                analytics.track(
                    .restoreCompleted,
                    context: AnalyticsEventContext(source: source.analyticsSource, outcome: .success)
                )
                celebrateProAccess()
            case .nothingToRestore:
                analytics.track(
                    .restoreCompleted,
                    context: AnalyticsEventContext(source: source.analyticsSource, outcome: .unavailable)
                )
                alert = .nothingToRestore
            case .failed(let error):
                analytics.track(
                    .restoreFailed,
                    context: AnalyticsEventContext(
                        source: source.analyticsSource,
                        outcome: .failure,
                        reason: analyticsReason(for: error)
                    )
                )
                alert = .restoreFailed(error.localizedDescription)
            }
        }
    }

    private func handlePurchaseCompleted() {
        if subscriptionStore.hasProAccess {
            funnelMilestones.record(.purchaseCompleted)
            analytics.track(
                .purchaseCompleted,
                context: AnalyticsEventContext(
                    source: source.analyticsSource,
                    outcome: .success
                )
            )
            celebrateProAccess()
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

    /// Pro can arrive from a purchase, a restore, or an approval made elsewhere;
    /// each one celebrates once and then lets the presenter carry on.
    private func celebrateProAccess() {
        guard subscriptionStore.hasProAccess, !didGrantProAccess else { return }
        didGrantProAccess = true
        alert = nil

        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.85)) {
            isCelebrating = true
        }
        onProAccessGranted?()
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

private enum PaywallAlert {
    case purchaseFailed(String)
    case paymentPending
    case nothingToRestore
    case restoreFailed(String)

    var title: String {
        switch self {
        case .purchaseFailed: String(localized: "Purchase Failed")
        case .paymentPending: String(localized: "Purchase Pending")
        case .nothingToRestore, .restoreFailed: String(localized: "Restore Purchases")
        }
    }

    var message: String {
        switch self {
        case .purchaseFailed(let message), .restoreFailed(let message):
            message
        case .paymentPending:
            String(localized: "Your purchase is waiting for approval. Pro unlocks as soon as it’s approved.")
        case .nothingToRestore:
            String(localized: "No active Glassy Desk Pro purchase was found. Check that you’re using the Apple Account used for your purchase.")
        }
    }
}
