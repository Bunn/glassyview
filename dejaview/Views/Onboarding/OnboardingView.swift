import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var selectedPage: OnboardingPage = .welcome

    let onComplete: (() -> Void)?

    init(onComplete: (() -> Void)? = nil) {
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            GeometryReader { geometry in
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        Group {
                            if verticalSizeClass == .compact, !dynamicTypeSize.isAccessibilitySize {
                                HStack(spacing: 28) {
                                    OnboardingIllustration(page: selectedPage)
                                        .frame(width: 260, height: 230)
                                    pageContent
                                }
                                .frame(maxWidth: 780)
                            } else {
                                VStack(spacing: 16) {
                                    OnboardingIllustration(page: selectedPage)
                                        .frame(height: illustrationHeight(in: geometry.size))
                                    pageContent
                                }
                                .frame(maxWidth: 460)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height)
                        .id("onboarding.top")
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .onChange(of: selectedPage) { _, _ in
                        scrollProxy.scrollTo("onboarding.top", anchor: .top)
                    }
                }
            }
            .clipped()

            OnboardingFooterView(selectedPage: selectedPage,
                                 completionTitle: onComplete == nil ? "Done" : "Let’s Connect",
                                 onPrimaryButtonTapped: advanceOrComplete)
        }
        .background {
            LinearGradient(colors: [Color(red: 0.025, green: 0.10, blue: 0.21),
                                    Color(red: 0.035, green: 0.055, blue: 0.12),
                                    Color(red: 0.02, green: 0.045, blue: 0.08)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.selection, trigger: selectedPage)
    }

    private var header: some View {
        HStack {
            Button("Back", systemImage: "chevron.left") {
                changePage(to: selectedPage.previous)
            }
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
            .opacity(selectedPage == .welcome ? 0 : 1)
            .disabled(selectedPage == .welcome)
            .accessibilityHidden(selectedPage == .welcome)
            .accessibilityIdentifier("onboarding.back")

            Spacer(minLength: 8)

            if !dynamicTypeSize.isAccessibilitySize {
                Text("Glassy Desk")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
            }

            Spacer(minLength: 8)

            Button(onComplete == nil ? "Close" : "Skip", action: complete)
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("onboarding.skip")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .background {
            Color(red: 0.025, green: 0.10, blue: 0.21)
                .ignoresSafeArea(edges: .top)
        }
    }

    private var pageContent: some View {
        OnboardingPageView(page: selectedPage)
            .id(selectedPage)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 12)),
                removal: .opacity.combined(with: .offset(y: -8))
            ))
    }

    private func illustrationHeight(in size: CGSize) -> CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 150 }
        return min(310, max(175, size.height * 0.46))
    }

    private func changePage(to page: OnboardingPage) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.45)) {
            selectedPage = page
        }
    }

    private func advanceOrComplete() {
        if selectedPage.isLast {
            complete()
        } else {
            changePage(to: selectedPage.next)
        }
    }

    private func complete() {
        if let onComplete {
            onComplete()
        } else {
            dismiss()
        }
    }
}

#Preview("First launch") {
    NavigationStack { OnboardingView(onComplete: {}) }
}

#Preview("Large text") {
    NavigationStack { OnboardingView() }
        .environment(\.dynamicTypeSize, .accessibility3)
}
