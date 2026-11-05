import Foundation

/// A major release worth interrupting a launch for. Only a few a year: bump
/// `current` when something big ships, and leave it alone for ordinary updates,
/// so that a new App Store version alone never shows the screen.
struct WhatsNewRelease: Equatable {
    struct Feature: Equatable, Identifiable {
        let systemImage: String
        let title: LocalizedStringResource
        let detail: LocalizedStringResource

        var id: String { systemImage }
    }

    /// Stored once announced, so a new value announces the release to everyone.
    let id: String
    let features: [Feature]
    let footnote: LocalizedStringResource?

    static let current = WhatsNewRelease(
        id: "3.4",
        features: [
            Feature(systemImage: "doc.on.doc",
                    title: "Copy from Your Mac",
                    detail: "Copy text on your Mac during a session, and it's ready to paste on this device."),
            Feature(systemImage: "doc.on.clipboard",
                    title: "Grab the Mac's Clipboard",
                    detail: "Choose Copy from Mac in the session menu to fetch what's already there, such as something a long-running job copied."),
            Feature(systemImage: "folder",
                    title: "Bring Over Copied Files",
                    detail: "Copy files in Finder, then tap Get Files to bring them to this device."),
        ],
        footnote: "Requires Fast Connection and Glassy Desk for Mac 3.1 or later."
    )
}

/// One review someone published on the App Store.
struct AppReviewTestimonial: Identifiable, Equatable {
    let id: String
    let rating: Int
    let title: String
    let body: String
    let author: String

    /// Only real App Store reviews, quoted verbatim. The review screen leaves
    /// the carousel out while this is empty.
    static let published: [AppReviewTestimonial] = []
}

/// What to show after a major update.
struct ReleaseAnnouncement: Identifiable, Equatable {
    let release: WhatsNewRelease
    let asksForReview: Bool

    var id: String { release.id }
}

/// Remembers which release was announced and when a rating was last requested.
struct ReleaseAnnouncementState {
    static let lastAnnouncedReleaseKey = "releaseAnnouncement.lastAnnouncedRelease"
    static let reviewRequestedDateKey = "releaseAnnouncement.reviewRequestedDate"
    /// StoreKit doesn't report whether someone rated, so tapping Rate is treated
    /// as having done it. This also matches the system's limit of three prompts a year.
    static let reviewCooldown: TimeInterval = 365 * 24 * 60 * 60

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// New installs learn about the app in onboarding, so only people who have
    /// finished it are told what changed. Only paying customers are asked for a
    /// rating, and someone who has never set up a Mac has nothing to rate yet.
    /// Everyone else sees the news without the review screen.
    func pendingAnnouncement(release: WhatsNewRelease = .current,
                             hasCompletedOnboarding: Bool,
                             hasUsedApp: Bool,
                             isPayingCustomer: Bool,
                             now: Date = .now) -> ReleaseAnnouncement? {
        guard hasCompletedOnboarding,
              defaults.string(forKey: Self.lastAnnouncedReleaseKey) != release.id else {
            return nil
        }
        return ReleaseAnnouncement(release: release,
                                   asksForReview: isPayingCustomer && hasUsedApp && !isInReviewCooldown(now: now))
    }

    func markAnnounced(_ release: WhatsNewRelease = .current) {
        defaults.set(release.id, forKey: Self.lastAnnouncedReleaseKey)
    }

    func recordReviewRequested(now: Date = .now) {
        defaults.set(now, forKey: Self.reviewRequestedDateKey)
    }

    private func isInReviewCooldown(now: Date) -> Bool {
        guard let requested = defaults.object(forKey: Self.reviewRequestedDateKey) as? Date else {
            return false
        }
        return now.timeIntervalSince(requested) < Self.reviewCooldown
    }
}
