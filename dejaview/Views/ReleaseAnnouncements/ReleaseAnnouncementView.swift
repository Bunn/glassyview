import SwiftUI

/// The What's New screen, followed by the review screen when one is due.
struct ReleaseAnnouncementView: View {
    private enum Step {
        case whatsNew
        case review
    }

    let announcement: ReleaseAnnouncement
    var testimonials = AppReviewTestimonial.published

    @Environment(\.analyticsTracker) private var analytics
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step = Step.whatsNew
    @State private var didAppear = false

    var body: some View {
        ZStack {
            switch step {
            case .whatsNew:
                WhatsNewView(release: announcement.release,
                             continuesToReview: announcement.asksForReview,
                             onContinue: finishWhatsNew)
                    .transition(stepTransition)
            case .review:
                AppReviewView(testimonials: testimonials)
                    .transition(stepTransition)
            }
        }
        .background {
            PaywallBackdrop(animates: !reduceMotion && scenePhase == .active)
        }
        .overlay(alignment: .topTrailing) {
            SheetCloseButton(action: dismiss.callAsFunction)
                .accessibilityIdentifier("releaseAnnouncement.close")
        }
        // The default iPad form sheet is too short for the full-height layout.
        .presentationSizing(.page)
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            track(.whatsNewViewed)
        }
    }

    private var stepTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                          removal: .move(edge: .leading).combined(with: .opacity))
    }

    private func finishWhatsNew() {
        guard announcement.asksForReview else {
            dismiss()
            return
        }
        track(.reviewPromptViewed)
        withAnimation(.snappy) {
            step = .review
        }
    }

    private func track(_ event: AnalyticsEventName) {
        analytics.track(event, context: AnalyticsEventContext(source: .whatsNew))
    }
}

/// Lists the release's headline features.
private struct WhatsNewView: View {
    let release: WhatsNewRelease
    let continuesToReview: Bool
    let onContinue: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ReleaseAnnouncementPage {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text("What's New")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(PaywallPalette.titleGradient(for: colorScheme))
                        .accessibilityAddTraits(.isHeader)

                    Text(verbatim: "Glassy Desk \(release.id)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    ForEach(release.features) { feature in
                        WhatsNewFeatureRow(feature: feature)
                    }
                }

                if let footnote = release.footnote {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .releaseAnnouncementColumn()
        } actions: {
            ReleaseAnnouncementActionButton(title: continuesToReview ? "Continue" : "Done",
                                            action: onContinue)
                .accessibilityIdentifier("whatsNew.continue")
        }
    }
}

private struct WhatsNewFeatureRow: View {
    let feature: WhatsNewRelease.Feature

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: feature.systemImage)
                .font(.title3.weight(.semibold))
                // The tile stays a fixed size, so the symbol has to fit inside it.
                .dynamicTypeSize(...DynamicTypeSize.large)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(PaywallPalette.actionGradient, in: .rect(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.headline)
                Text(feature.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(PaywallPalette.cardFill(for: colorScheme), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(PaywallPalette.cardStroke(for: colorScheme))
        }
        .accessibilityElement(children: .combine)
    }
}

/// A shared frame: content centered when it fits and scrolling when it doesn't,
/// such as at large text sizes or on a folded iPhone Duo, above fixed actions.
struct ReleaseAnnouncementPage<Content: View, Actions: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        ScrollView {
            VStack(spacing: 24) { content }
                .padding(.top, 56)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .safeAreaBar(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) { actions }
                .releaseAnnouncementColumn()
                .padding(.vertical, 12)
        }
    }
}

extension View {
    /// Keeps text a readable width on iPad and in wide windows.
    func releaseAnnouncementColumn() -> some View {
        frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
    }
}

struct ReleaseAnnouncementActionButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(PaywallPalette.actionGradient, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

#Preview("What's New, then review") {
    ReleaseAnnouncementView(announcement: ReleaseAnnouncement(release: .current, asksForReview: true))
}

#if DEBUG
/// Launch with `-whatsNewPreview 1` to open the flow straight away, for screenshots
/// and QA without tapping through the app. `-whatsNewPreview testimonials` also fills
/// the carousel with placeholder text that is compiled out of release builds.
struct ReleaseAnnouncementLaunchPreview: ViewModifier {
    @State private var mode = UserDefaults.standard.string(forKey: "whatsNewPreview")

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding { mode != nil } set: { if !$0 { mode = nil } }) {
            ReleaseAnnouncementView(
                announcement: ReleaseAnnouncement(release: .current, asksForReview: true),
                testimonials: mode == "testimonials" ? Self.placeholderTestimonials : AppReviewTestimonial.published
            )
        }
    }

    private static let placeholderTestimonials = (1...3).map {
        AppReviewTestimonial(id: "\($0)", rating: 5, title: "Placeholder title \($0)",
                             body: "Placeholder text to check how a real review lays out in the carousel.",
                             author: "Placeholder")
    }
}
#endif
