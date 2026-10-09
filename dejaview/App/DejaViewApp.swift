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

        switch AnalyticsRuntime.mode {
        case .production:
            analytics = CloudflareAnalyticsTracker.live()
            funnelMilestones = RevenueCatFunnelMilestoneTracker()
        case .console:
            #if DEBUG
            analytics = DebugConsoleAnalyticsTracker()
            funnelMilestones = RevenueCatFunnelMilestoneTracker.consoleOnly()
            #else
            analytics = NoOpAnalyticsTracker()
            funnelMilestones = NoOpFunnelMilestoneTracker()
            #endif
        case .disabled:
            analytics = NoOpAnalyticsTracker()
            funnelMilestones = NoOpFunnelMilestoneTracker()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(AppLockCoverInstaller())
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
                }
                .task {
                    await subscriptionStore.observeCustomerInfoUpdates()
                }
        }
        .modelContainer(DejaViewModelContainer.shared)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            AppLog.app.info("Scene phase changed to \(String(describing: newPhase), privacy: .public)")

            switch newPhase {
            case .active: AppLockController.shared.sceneBecameActive()
            case .inactive: AppLockController.shared.sceneBecameInactive()
            case .background: AppLockController.shared.sceneEnteredBackground()
            @unknown default: break
            }

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
            updateAnalyticsCollection(enabled)
        }
    }

    private func updateAnalyticsCollection(_ enabled: Bool) {
        funnelMilestones.setCollectionEnabled(enabled)

        analytics.setCollectionEnabled(enabled)
    }
}
