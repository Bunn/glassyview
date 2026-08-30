import SwiftUI
import OSLog
import SwiftData

@main
struct DejaViewApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var subscriptionStore = SubscriptionStore()
    @State private var hasRecordedInitialOpen = false
    @AppStorage(AnalyticsPreference.collectionEnabledKey)
    private var analyticsEnabled = AnalyticsPreference.defaultCollectionEnabled

    private let analytics: any AnalyticsTracking
    private let funnelMilestones: any FunnelMilestoneTracking

    init() {
        RevenueCatConfiguration.configure()

        if AnalyticsRuntime.shouldRunProductionAnalytics {
            analytics = CloudflareAnalyticsTracker.live()
            funnelMilestones = RevenueCatFunnelMilestoneTracker()
        } else {
            analytics = NoOpAnalyticsTracker()
            funnelMilestones = NoOpFunnelMilestoneTracker()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(subscriptionStore)
                .environment(\.analyticsTracker, analytics)
                .environment(\.funnelMilestoneTracker, funnelMilestones)
                .task {
                    analytics.setCollectionEnabled(analyticsEnabled)
                    funnelMilestones.setCollectionEnabled(analyticsEnabled)

                    if !hasRecordedInitialOpen {
                        hasRecordedInitialOpen = true
                        analytics.track(
                            .appOpened,
                            context: AnalyticsEventContext(
                                source: .app,
                                outcome: .success
                            )
                        )
                    }

                    await subscriptionStore.refresh()
                    await subscriptionStore.observeCustomerInfoUpdates()
                }
        }
        .modelContainer(DejaViewModelContainer.shared)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            AppLog.app.info("Scene phase changed to \(String(describing: newPhase), privacy: .public)")

            if newPhase == .background {
                analytics.flush()
            } else if oldPhase == .background, newPhase == .active {
                analytics.track(
                    .appOpened,
                    context: AnalyticsEventContext(source: .app, outcome: .success)
                )
            }
        }
        .onChange(of: analyticsEnabled) { _, enabled in
            analytics.setCollectionEnabled(enabled)
            funnelMilestones.setCollectionEnabled(enabled)
        }
    }
}
