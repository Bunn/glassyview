import StoreKit
import SwiftUI

/// Asks for a rating right after the What's New screen. The system decides whether
/// its rating prompt appears and doesn't say whether it did, so the main button moves
/// on to the optional written review either way. Feedback is offered to everyone
/// alongside the rating, and nothing here depends on how someone feels about the app.
struct AppReviewView: View {
    let testimonials: [AppReviewTestimonial]

    @Environment(\.analyticsTracker) private var analytics
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview

    @State private var hasRequestedRating = false

    var body: some View {
        ReleaseAnnouncementPage {
            header
                .releaseAnnouncementColumn()

            if !testimonials.isEmpty {
                AppReviewCarousel(testimonials: testimonials)
            }
        } actions: {
            actions
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "laurel.leading")
                    .font(.system(size: 52))
                ForEach(0..<5, id: \.self) { _ in
                    Image(systemName: "star.fill")
                        .font(.title2)
                }
                Image(systemName: "laurel.trailing")
                    .font(.system(size: 52))
            }
            .foregroundStyle(PaywallPalette.titleGradient(for: colorScheme))
            .accessibilityHidden(true)

            Text("Help Glassy Desk Grow")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(PaywallPalette.titleGradient(for: colorScheme))
                .accessibilityAddTraits(.isHeader)

            Text("Your rating helps other Mac owners find Glassy Desk and shows what to build next. It only takes a moment.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }

    private var actions: some View {
        Group {
            if hasRequestedRating {
                Text("Want to say more? You can add a written review too.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            ReleaseAnnouncementActionButton(title: hasRequestedRating ? "Write a Review" : "Rate Glassy Desk",
                                            action: hasRequestedRating ? writeReview : rate)
                .accessibilityIdentifier("review.primaryAction")

            Button(action: sendFeedback) {
                Text("Something not working? **Send Feedback**")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("review.sendFeedback")
        }
    }

    private func rate() {
        track(.reviewRateTapped)
        ReleaseAnnouncementState().recordReviewRequested()
        requestReview()
        withAnimation(.snappy) {
            hasRequestedRating = true
        }
    }

    private func writeReview() {
        track(.reviewWriteTapped)
        openURL(GlassyDeskLinks.writeReview)
    }

    private func sendFeedback() {
        track(.reviewFeedbackTapped)
        openURL(GlassyDeskLinks.sendFeedback)
    }

    private func track(_ event: AnalyticsEventName) {
        analytics.track(event, context: AnalyticsEventContext(source: .whatsNew))
    }
}

private struct AppReviewCarousel: View {
    let testimonials: [AppReviewTestimonial]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(testimonials) { testimonial in
                    card(for: testimonial)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .safeAreaPadding(.horizontal, 20)
    }

    private func card(for testimonial: AppReviewTestimonial) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                ForEach(0..<testimonial.rating, id: \.self) { _ in
                    Image(systemName: "star.fill")
                }
            }
            .font(.caption)
            .foregroundStyle(PaywallPalette.blue)
            .accessibilityHidden(true)

            Text(verbatim: testimonial.title)
                .font(.subheadline.weight(.semibold))
            Text(verbatim: testimonial.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(5)
            Text(verbatim: testimonial.author)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PaywallPalette.cardFill(for: colorScheme), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(PaywallPalette.cardStroke(for: colorScheme))
        }
        .accessibilityElement(children: .combine)
    }
}
