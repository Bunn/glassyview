import Foundation

/// A release with notes worth reading. The newest one is announced once after
/// launch, and all of them are listed in Settings under What's New.
///
/// Only add releases with real news, a few a year: a new App Store version on its
/// own never shows the screen, and bug-fix releases stay out of the list.
struct WhatsNewRelease: Equatable, Identifiable {
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

    /// The release announced after launch.
    static var current: WhatsNewRelease { all[0] }

    /// Every release with notes, newest first.
    static let all: [WhatsNewRelease] = [
        WhatsNewRelease(
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
        ),
        WhatsNewRelease(
            id: "3.0",
            features: [
                Feature(systemImage: "iphone",
                        title: "Made for iPhone Duo",
                        detail: "Layouts adapt to the fold. Half-folded, the lower half becomes a trackpad with an optional keyboard."),
                Feature(systemImage: "pip",
                        title: "Picture in Picture",
                        detail: "Keep watching your Mac while you use other apps."),
                Feature(systemImage: "doc.badge.arrow.up",
                        title: "File Transfer",
                        detail: "Send files and photos to your Mac, and bring files from the Mac's Finder into the Files app."),
                Feature(systemImage: "eye.slash",
                        title: "Curtain Mode",
                        detail: "Cover the Mac's screen and keep anyone at the Mac from using it while you're connected."),
                Feature(systemImage: "lock.shield",
                        title: "App Lock",
                        detail: "Protect Glassy Desk with Face ID, Touch ID, or your passcode."),
                Feature(systemImage: "applepencil.tip",
                        title: "Apple Pencil",
                        detail: "A precise pointer with hover, plus double-tap and squeeze actions."),
                Feature(systemImage: "rectangle.on.rectangle",
                        title: "Siri and Shortcuts in Every Window",
                        detail: "Siri and Shortcuts now work reliably when Glassy Desk has more than one window open."),
            ],
            footnote: "File Transfer and Curtain Mode require Fast Connection."
        ),
        WhatsNewRelease(
            id: "2.0",
            features: [
                Feature(systemImage: "desktopcomputer",
                        title: "Glassy Desk for Mac",
                        detail: "Install the companion app on your Mac and choose Fast Connection for faster, more responsive sessions. Pair by scanning the code on your Mac or entering it."),
                Feature(systemImage: "keyboard",
                        title: "Keyboard and Trackpad Mode",
                        detail: "With Standard VNC and an external display, your iPhone or iPad becomes a keyboard and trackpad while your desktop stays on the bigger screen."),
                Feature(systemImage: "slider.horizontal.3",
                        title: "Clearer Connection Setup",
                        detail: "VNC options are always visible, and saved Macs keep their connection type when you edit them."),
            ],
            footnote: nil
        ),
        WhatsNewRelease(
            id: "1.2",
            features: [
                Feature(systemImage: "ellipsis.circle",
                        title: "A New Controls Menu",
                        detail: "A streamlined menu gives your desktop more room, whether it's expanded or collapsed."),
                Feature(systemImage: "keyboard",
                        title: "Better Typing",
                        detail: "Your content stays visible and is easier to reposition while you type."),
            ],
            footnote: nil
        ),
    ]
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
