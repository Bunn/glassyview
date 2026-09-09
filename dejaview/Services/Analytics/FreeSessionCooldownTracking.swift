import Foundation

/// A cooldown is viewed once per session-screen visit, even if a paywall or
/// app backgrounding causes SwiftUI to present the same content again.
@MainActor
struct FreeSessionCooldownTracking {
    private var viewedCooldownEndDate: Date?

    mutating func recordView(
        of cooldown: FreeSessionCooldown,
        sessionType: AnalyticsSessionType,
        analytics: any AnalyticsTracking,
        milestones: any FunnelMilestoneTracking
    ) {
        guard viewedCooldownEndDate != cooldown.endDate else { return }
        viewedCooldownEndDate = cooldown.endDate
        milestones.record(.freeSessionCooldownViewed)
        analytics.track(
            .freeSessionCooldownViewed,
            context: AnalyticsEventContext(source: .freeSessionCooldown, sessionType: sessionType)
        )
    }

    func recordUpgradeTap(
        sessionType: AnalyticsSessionType,
        analytics: any AnalyticsTracking,
        milestones: any FunnelMilestoneTracking
    ) {
        milestones.record(.freeSessionCooldownUpgradeTapped)
        analytics.track(
            .freeSessionCooldownUpgradeTapped,
            context: AnalyticsEventContext(source: .freeSessionCooldown, sessionType: sessionType)
        )
    }
}
