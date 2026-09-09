import SwiftUI

struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 16) {
            Text(page.title)
                .font(.largeTitle.weight(.bold))
                .tracking(-0.8)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("onboarding.title")

            Text(page.subtitle)
                .font(.body)
                .foregroundStyle(.white.opacity(0.7))
                .lineSpacing(3)

            if page == .pair {
                GlassyHostDownloadLink()
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
                    .frame(minHeight: 44)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 380)
    }
}
