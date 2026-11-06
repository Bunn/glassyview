import Foundation
import Testing
@testable import GlassyDesk

@MainActor
@Suite("Release announcement and review timing")
struct ReleaseAnnouncementTests {
    private let release = WhatsNewRelease(id: "9.0", features: [], footnote: nil)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeState() -> ReleaseAnnouncementState {
        let suite = "ReleaseAnnouncementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ReleaseAnnouncementState(defaults: defaults)
    }

    private func pending(_ state: ReleaseAnnouncementState,
                         release: WhatsNewRelease? = nil,
                         hasCompletedOnboarding: Bool = true,
                         hasUsedApp: Bool = true,
                         isPayingCustomer: Bool = true,
                         at date: Date? = nil) -> ReleaseAnnouncement? {
        state.pendingAnnouncement(release: release ?? self.release,
                                  hasCompletedOnboarding: hasCompletedOnboarding,
                                  hasUsedApp: hasUsedApp,
                                  isPayingCustomer: isPayingCustomer,
                                  now: date ?? now)
    }

    @Test("A paying customer updating to a major release sees What's New, then the review screen")
    func existingUser() {
        #expect(pending(makeState()) == ReleaseAnnouncement(release: release, asksForReview: true))
    }

    @Test("Someone who hasn't finished onboarding sees nothing")
    func beforeOnboarding() {
        #expect(pending(makeState(), hasCompletedOnboarding: false) == nil)
    }

    @Test("A new install doesn't see the release it onboarded on, but sees the next one")
    func newInstall() {
        let state = makeState()
        state.markAnnounced(release)
        #expect(pending(state) == nil)
        #expect(pending(state, release: WhatsNewRelease(id: "10.0", features: [], footnote: nil)) != nil)
    }

    @Test("A release is announced once")
    func announcedOnce() {
        let state = makeState()
        state.markAnnounced(release)
        #expect(pending(state) == nil)
    }

    @Test("Someone with no saved or recent Mac gets the news without the review screen")
    func unusedApp() {
        #expect(pending(makeState(), hasUsedApp: false)?.asksForReview == false)
    }

    @Test("Someone who isn't paying gets the news without the review screen")
    func notPaying() {
        let announcement = pending(makeState(), isPayingCustomer: false)
        #expect(announcement?.release == release)
        #expect(announcement?.asksForReview == false)
    }

    @Test("Declining the review screen leaves the next major release free to ask again")
    func declined() {
        let state = makeState()
        state.markAnnounced(release)
        let next = WhatsNewRelease(id: "10.0", features: [], footnote: nil)
        #expect(pending(state, release: next)?.asksForReview == true)
    }

    @Test("Tapping Rate pauses the review screen for a year, but not What's New")
    func cooldown() {
        let state = makeState()
        state.recordReviewRequested(now: now)
        let nearlyOver = now.addingTimeInterval(ReleaseAnnouncementState.reviewCooldown - 1)
        let over = now.addingTimeInterval(ReleaseAnnouncementState.reviewCooldown)

        #expect(pending(state, at: nearlyOver)?.asksForReview == false)
        #expect(pending(state, at: over)?.asksForReview == true)
    }

    @Test("The shipped releases have content and no invented reviews")
    func shippedContent() {
        #expect(WhatsNewRelease.current == WhatsNewRelease.all.first)
        for release in WhatsNewRelease.all {
            #expect(!release.features.isEmpty, "\(release.id) has no features")
            #expect(Set(release.features.map(\.id)).count == release.features.count, "\(release.id) repeats a feature")
        }
        #expect(AppReviewTestimonial.published.allSatisfy { (1...5).contains($0.rating) })
    }

    @Test("The release list is newest first, with one entry per version")
    func releaseOrder() {
        let versions = WhatsNewRelease.all.map { $0.id.split(separator: ".").compactMap { Int($0) } }
        #expect(Set(WhatsNewRelease.all.map(\.id)).count == WhatsNewRelease.all.count)
        #expect(zip(versions, versions.dropFirst()).allSatisfy { $0.lexicographicallyPrecedes($1) == false && $0 != $1 })
    }

    @Test("The launch announces the newest release")
    func announcesNewest() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let state = ReleaseAnnouncementState(defaults: defaults)

        let announcement = state.pendingAnnouncement(hasCompletedOnboarding: true, hasUsedApp: true,
                                                     isPayingCustomer: false)
        #expect(announcement?.release.id == WhatsNewRelease.all.first?.id)
    }

    @Test("Events use the names and source the Worker allows")
    func analyticsNames() {
        #expect(AnalyticsEventSource.whatsNew.rawValue == "whats_new")
        #expect(AnalyticsEventName.whatsNewViewed.rawValue == "whats_new_viewed")
        #expect(AnalyticsEventName.reviewPromptViewed.rawValue == "review_prompt_viewed")
        #expect(AnalyticsEventName.reviewRateTapped.rawValue == "review_rate_tapped")
        #expect(AnalyticsEventName.reviewWriteTapped.rawValue == "review_write_tapped")
        #expect(AnalyticsEventName.reviewFeedbackTapped.rawValue == "review_feedback_tapped")
    }

    @Test("The review link opens the write-review page of Glassy Desk's listing")
    func links() {
        #expect(GlassyDeskLinks.writeReview.absoluteString.contains("id6787767486"))
        #expect(GlassyDeskLinks.writeReview.query == "action=write-review")
        #expect(GlassyDeskLinks.sendFeedback.scheme == "mailto")
    }
}
