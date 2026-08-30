import Foundation
import Testing
@testable import GlassyDesk

@MainActor
private final class RevenueCatAttributeWriterSpy: RevenueCatAttributeWriting {
    var isConfigured: Bool
    private(set) var writes: [[String: String]] = []

    init(isConfigured: Bool = true) {
        self.isConfigured = isConfigured
    }

    func setAttributes(_ attributes: [String: String]) {
        writes.append(attributes)
    }
}

@MainActor
@Suite("RevenueCat analytics funnel")
struct FunnelMilestoneTrackingTests {
    @Test("A fixed milestone is written only once")
    func recordsMilestoneOnlyOnce() {
        let revenueCat = RevenueCatAttributeWriterSpy()
        let tracker = makeTracker(revenueCat: revenueCat)
        tracker.setCollectionEnabled(true)

        tracker.record(.freeSessionLimitReached)
        tracker.record(.freeSessionLimitReached)

        #expect(revenueCat.writes == [["gv_ms_free_limit_reached": "1"]])
    }

    @Test("Free sessions update only coarse usage bands")
    func recordsCoarseFreeSessionBands() {
        let revenueCat = RevenueCatAttributeWriterSpy()
        let tracker = makeTracker(revenueCat: revenueCat)
        tracker.setCollectionEnabled(true)

        let kinds = (1...11).map { _ in tracker.recordFreeSessionStarted() }

        #expect(kinds.first == .first)
        #expect(kinds.dropFirst().allSatisfy { $0 == .returning })
        let bandWrites = revenueCat.writes.compactMap { $0["gv_free_session_band"] }
        #expect(bandWrites == ["1", "2", "3_5", "6_10", "11_plus"])
        #expect(revenueCat.writes.count(where: {
            $0["gv_ms_free_session_restarted"] == "1"
        }) == 1)
    }

    @Test("A session after the limit is classified as a refresh")
    func detectsRefreshAfterLimit() {
        let revenueCat = RevenueCatAttributeWriterSpy()
        let tracker = makeTracker(revenueCat: revenueCat)
        tracker.setCollectionEnabled(true)

        #expect(tracker.recordFreeSessionStarted() == .first)
        tracker.recordFreeSessionLimitReached()
        #expect(tracker.recordFreeSessionStarted() == .restartedAfterLimit)
        #expect(revenueCat.writes.contains([
            "gv_ms_refresh_after_limit": "1",
        ]))
    }

    @Test("Opt-out clears local funnel state and stops writes")
    func optOutClearsLocalState() {
        let revenueCat = RevenueCatAttributeWriterSpy()
        let tracker = makeTracker(revenueCat: revenueCat)
        tracker.setCollectionEnabled(true)
        _ = tracker.recordFreeSessionStarted()

        tracker.setCollectionEnabled(false)
        _ = tracker.recordFreeSessionStarted()
        let writeCountWhileDisabled = revenueCat.writes.count

        tracker.setCollectionEnabled(true)
        #expect(tracker.recordFreeSessionStarted() == .first)
        #expect(revenueCat.writes.count == writeCountWhileDisabled + 2)
    }

    @Test("Attribute schema is fixed, unique, and bounded")
    func attributeSchemaIsValid() {
        let keys = FunnelMilestone.allCases.map(\.revenueCatAttributeKey)
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_-")
        )

        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { !$0.isEmpty && $0.count <= 40 })
        #expect(keys.allSatisfy {
            $0.unicodeScalars.allSatisfy(allowed.contains)
        })
    }

    private func makeTracker(
        revenueCat: RevenueCatAttributeWriterSpy
    ) -> RevenueCatFunnelMilestoneTracker {
        let suiteName = "FunnelMilestoneTrackingTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)

        return RevenueCatFunnelMilestoneTracker(
            revenueCat: revenueCat,
            defaults: defaults,
            productionAnalyticsEnabled: { true }
        )
    }
}
