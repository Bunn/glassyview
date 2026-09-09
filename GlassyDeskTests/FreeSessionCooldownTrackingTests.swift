import Foundation
import Testing
@testable import GlassyDesk

@MainActor
private final class CooldownAnalyticsSpy: AnalyticsTracking {
    var events: [(name: AnalyticsEventName, context: AnalyticsEventContext?)] = []
    func setCollectionEnabled(_ enabled: Bool) {}
    func track(_ event: AnalyticsEventName, context: AnalyticsEventContext?) {
        events.append((event, context))
    }
    func flush() {}
}

@MainActor
private final class CooldownMilestonesSpy: FunnelMilestoneTracking {
    var milestones: [FunnelMilestone] = []
    func setCollectionEnabled(_ enabled: Bool) {}
    func record(_ milestone: FunnelMilestone) { milestones.append(milestone) }
    func recordFreeSessionStarted() -> FreeSessionStartKind { .first }
    func recordFreeSessionLimitReached() {}
}

@MainActor
@Suite("Cooldown conversion tracking")
struct FreeSessionCooldownTrackingTests {
    @Test("Reappearing after a paywall or backgrounding does not duplicate the cooldown view")
    func deduplicatesViews() {
        let analytics = CooldownAnalyticsSpy()
        let milestones = CooldownMilestonesSpy()
        var tracking = FreeSessionCooldownTracking()
        let cooldown = FreeSessionCooldown(endDate: Date(timeIntervalSince1970: 90))
        for _ in 0..<3 {
            tracking.recordView(of: cooldown, sessionType: .vnc,
                                analytics: analytics, milestones: milestones)
        }
        #expect(analytics.events.map(\.name) == [.freeSessionCooldownViewed])
        #expect(analytics.events.first?.context == AnalyticsEventContext(
            source: .freeSessionCooldown, sessionType: .vnc
        ))
        #expect(milestones.milestones == [.freeSessionCooldownViewed])

        tracking.recordView(of: FreeSessionCooldown(endDate: cooldown.endDate.addingTimeInterval(90)),
                            sessionType: .glassyStream, analytics: analytics, milestones: milestones)
        #expect(analytics.events.count == 2)
        #expect(analytics.events.last?.context?.sessionType == .glassyStream)
    }

    @Test("A reopened session screen records a visit to its restored cooldown")
    func recordsRestoredCooldown() {
        let analytics = CooldownAnalyticsSpy()
        let milestones = CooldownMilestonesSpy()
        let cooldown = FreeSessionCooldown(endDate: Date(timeIntervalSince1970: 90))
        for _ in 0..<2 {
            var tracking = FreeSessionCooldownTracking()
            tracking.recordView(of: cooldown, sessionType: .vnc,
                                analytics: analytics, milestones: milestones)
        }
        #expect(analytics.events.map(\.name) == [.freeSessionCooldownViewed, .freeSessionCooldownViewed])
    }

    @Test("Repeated upgrade actions retain the cooldown source and connection type")
    func recordsUpgradeActions() {
        let analytics = CooldownAnalyticsSpy()
        let milestones = CooldownMilestonesSpy()
        let tracking = FreeSessionCooldownTracking()
        for _ in 0..<2 {
            tracking.recordUpgradeTap(sessionType: .glassyStream, analytics: analytics, milestones: milestones)
        }
        #expect(analytics.events.map(\.name) == [.freeSessionCooldownUpgradeTapped, .freeSessionCooldownUpgradeTapped])
        #expect(analytics.events.allSatisfy { $0.context == AnalyticsEventContext(
            source: .freeSessionCooldown, sessionType: .glassyStream
        ) })
        #expect(milestones.milestones == [.freeSessionCooldownUpgradeTapped, .freeSessionCooldownUpgradeTapped])
    }

    @Test("Cooldown paywall attribution is separate from existing timer and limit sources")
    func paywallAttribution() {
        #expect(PaywallSource.freeSessionCooldown.analyticsSource.rawValue == "free_session_cooldown")
        #expect(PaywallSource.freeSessionCooldown.funnelMilestone == .paywallCooldownPresented)
        #expect(PaywallSource.sessionLimit.analyticsSource == .sessionLimit)
        #expect(PaywallSource.sessionLimit.funnelMilestone == .paywallSessionLimitPresented)
        #expect(PaywallSource.freeSessionTimer.analyticsSource == .freeSessionTimer)
    }
}
