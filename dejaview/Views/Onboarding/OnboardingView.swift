import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPage: OnboardingPage = .welcome
    @AppStorage(AnalyticsPreference.collectionEnabledKey)
    private var analyticsEnabled = AnalyticsPreference.defaultCollectionEnabled

    let onComplete: (() -> Void)?

    init(onComplete: (() -> Void)? = nil) {
        self.onComplete = onComplete
    }

    var body: some View {
        TabView(selection: $selectedPage) {
            ForEach(OnboardingPage.allCases) { page in
                ScrollView {
                    VStack(spacing: 24) {
                        OnboardingPageView(page: page)
                        if page.isLast {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("Share Optional Analytics", isOn: $analyticsEnabled)
                                Text("Help improve Glassy Desk by sharing aggregate app events and limited usage milestones linked to your anonymous purchase profile. Screen content, input, Mac addresses, and credentials are never included. You can change this in Settings.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Link("Privacy Policy", destination: GlassyDeskLinks.privacyPolicy)
                            }
                            .padding()
                            .background(.quaternary, in: .rect(cornerRadius: 16))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                    .padding(.bottom, 120)
                    .frame(maxWidth: .infinity)
                }
                .tag(page)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            OnboardingFooterView(selectedPage: selectedPage,
                                 completionTitle: onComplete == nil ? "Done" : "Get Started",
                                 onPrimaryButtonTapped: advanceOrComplete)
        }
        .navigationTitle("Getting Started")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if onComplete != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip", action: complete)
                }
            }
        }
    }

    private func advanceOrComplete() {
        if selectedPage.isLast {
            complete()
        } else {
            withAnimation {
                selectedPage = selectedPage.next
            }
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

#Preview {
    NavigationStack {
        OnboardingView()
    }
}
