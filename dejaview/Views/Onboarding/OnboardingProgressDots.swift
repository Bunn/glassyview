import SwiftUI

struct OnboardingProgressDots: View {
    let selectedPage: OnboardingPage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingPage.allCases) { page in
                Capsule()
                    .fill(.white.opacity(page == selectedPage ? 0.95 : 0.25))
                    .frame(width: page == selectedPage ? 24 : 7, height: 7)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: selectedPage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(selectedPage.rawValue + 1) of \(OnboardingPage.allCases.count)")
    }
}
