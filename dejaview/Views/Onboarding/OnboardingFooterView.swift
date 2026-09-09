import SwiftUI

struct OnboardingFooterView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let selectedPage: OnboardingPage
    let completionTitle: LocalizedStringResource
    let onPrimaryButtonTapped: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            OnboardingProgressDots(selectedPage: selectedPage)

            primaryButton
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onboarding.continue")
        }
        .frame(maxWidth: 380)
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background {
            Color(red: 0.02, green: 0.045, blue: 0.08)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Button(action: onPrimaryButtonTapped) {
                primaryButtonLabel
                    .padding(.vertical, 16)
                    .background(.white, in: .rect(cornerRadius: 28))
            }
            .buttonStyle(.plain)
        } else {
            Button(action: onPrimaryButtonTapped) {
                primaryButtonLabel
            }
            .buttonStyle(.glassProminent)
            .tint(.white)
            .controlSize(.large)
        }
    }

    private var primaryButtonLabel: some View {
        HStack(spacing: 10) {
            Text(selectedPage.isLast ? String(localized: completionTitle) : String(localized: "Continue"))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
            if !dynamicTypeSize.isAccessibilitySize {
                Image(systemName: "arrow.right")
                    .accessibilityHidden(true)
            }
        }
        .font(.headline)
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity, minHeight: 28)
    }
}
