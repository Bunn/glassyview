import SwiftUI

struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: page.systemImage)
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 74, height: 74)
                    .background(.thinMaterial, in: .rect(cornerRadius: 22))
                    .accessibilityHidden(true)

                Text(page.title)
                    .font(.title)
                    .bold()
                    .fixedSize(horizontal: false, vertical: true)

                Text(page.subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if page == .setup, FeatureFlags.isGlassyStreamEnabled {
                GlassyHostDownloadLink()
            }

            VStack(spacing: 10) {
                ForEach(page.bullets) { bullet in
                    OnboardingBulletRow(bullet: bullet)
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
    }
}
