import RevenueCat
import SwiftUI

struct SettingsView: View {
    @Environment(SubscriptionStore.self) private var subscriptionStore

    @AppStorage(AnalyticsPreference.collectionEnabledKey)
    private var analyticsEnabled = AnalyticsPreference.defaultCollectionEnabled

    @State private var isPaywallPresented = false

    var body: some View {
        @Bindable var subscriptionStore = subscriptionStore

        Form {
            Section("Account") {
                Button(action: openProUpgradeIfNeeded) {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(proStatusText)
                                .foregroundStyle(proStatusColor)

                            if !subscriptionStore.hasProAccess {
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } label: {
                        Label("Glassy Desk Pro", systemImage: proSystemImage)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let managementURL = subscriptionStore.managementURL {
                    Link(destination: managementURL) {
                        Label("Manage Subscription", systemImage: "link")
                    }
                }
            }

            Section("Getting Started") {
                if FeatureFlags.isGlassyStreamEnabled {
                    GlassyHostDownloadLink()
                }

                NavigationLink {
                    RemoteConnectionInfoView(usesVNC: !FeatureFlags.isGlassyStreamEnabled)
                } label: {
                    Label("Connect away from home", systemImage: "globe")
                }
                .accessibilityIdentifier("settings.remote-guide")

                NavigationLink {
                    OnboardingView()
                } label: {
                    Label("How Glassy Desk Works", systemImage: "sparkles.rectangle.stack")
                }
            }

            Section("FAQ") {
                NavigationLink {
                    FAQView()
                } label: {
                    Label("Frequently Asked Questions", systemImage: "questionmark.circle")
                }
            }

            Section {
                Toggle("Share Anonymous Analytics", isOn: $analyticsEnabled)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Your analytics are private. No identifiable information is ever sent.")
            }

            #if DEBUG
            debugPaymentsSection
            #endif

            Section("About") {
                NavigationLink {
                    AboutView()
                } label: {
                    Label("About Glassy Desk", systemImage: "info.circle")
                }
            }
        }
        .refreshable {
            await subscriptionStore.refresh()
        }
        .task {
            await subscriptionStore.refresh()
        }
        .alert("Subscription Error", isPresented: $subscriptionStore.isErrorPresented) {
        } message: {
            Text(subscriptionStore.errorMessage)
        }
        .sheet(isPresented: $isPaywallPresented) {
            RevenueCatPaywallSheet()
        }
        .onChange(of: subscriptionStore.hasProAccess) { _, hasProAccess in
            if hasProAccess {
                isPaywallPresented = false
            }
        }
    }

    private var proStatusText: String {
        if subscriptionStore.customerInfo == nil && subscriptionStore.isRefreshing {
            String(localized: "Checking")
        } else if subscriptionStore.hasProAccess {
            String(localized: "Active")
        } else {
            String(localized: "Free")
        }
    }

    private var proStatusColor: Color {
        subscriptionStore.hasProAccess ? .green : .secondary
    }

    private var proSystemImage: String {
        subscriptionStore.hasProAccess ? "checkmark.seal.fill" : "sparkles"
    }

    private func openProUpgradeIfNeeded() {
        guard !subscriptionStore.hasProAccess else { return }
        isPaywallPresented = true
    }

    #if DEBUG
    private var debugPaymentsSection: some View {
        Section("Debug - Payments") {
            LabeledContent("Configured", value: Purchases.isConfigured ? "Yes" : "No")

            if Purchases.isConfigured {
                LabeledContent("App User ID", value: Purchases.shared.appUserID)
                LabeledContent("Anonymous", value: Purchases.shared.isAnonymous ? "Yes" : "No")
                LabeledContent("Sandbox", value: Purchases.shared.isSandbox ? "Yes" : "No")
            }

            LabeledContent("Entitlement", value: SubscriptionStore.proEntitlementIdentifier)
            LabeledContent("Pro Active", value: subscriptionStore.hasProAccess ? "Yes" : "No")
            LabeledContent("Current Offering", value: subscriptionStore.currentOffering?.identifier ?? "None")
            LabeledContent("Active Product", value: subscriptionStore.activeProductIdentifier ?? "None")
            LabeledContent("Active Subscriptions", value: activeSubscriptionsText)
            LabeledContent("Purchased Products", value: purchasedProductsText)

            if let entitlement = subscriptionStore.proEntitlement {
                LabeledContent("Will Renew", value: entitlement.willRenew ? "Yes" : "No")
                LabeledContent("Entitlement Sandbox", value: entitlement.isSandbox ? "Yes" : "No")
            }

            Button("Refresh Payment State", systemImage: "arrow.clockwise", action: refreshPaymentState)
                .disabled(subscriptionStore.isRefreshing)

            Button("Restore Purchases", systemImage: "arrow.uturn.backward", action: restorePurchases)
                .disabled(subscriptionStore.isRestoring)

            Button("Open Paywall", systemImage: "creditcard", action: openPaywallForDebug)
        }
    }

    private var activeSubscriptionsText: String {
        formattedIdentifiers(subscriptionStore.customerInfo?.activeSubscriptions ?? [])
    }

    private var purchasedProductsText: String {
        formattedIdentifiers(subscriptionStore.customerInfo?.allPurchasedProductIdentifiers ?? [])
    }

    private func formattedIdentifiers(_ identifiers: some Collection<String>) -> String {
        guard !identifiers.isEmpty else { return String(localized: "None") }
        return identifiers.sorted().joined(separator: ", ")
    }

    private func refreshPaymentState() {
        Task {
            await subscriptionStore.refresh()
        }
    }

    private func restorePurchases() {
        Task {
            await subscriptionStore.restorePurchases()
        }
    }

    private func openPaywallForDebug() {
        isPaywallPresented = true
    }
    #endif
}

#Preview {
    NavigationStack {
        SettingsView()
            .navigationTitle("Settings")
    }
    .environment(SubscriptionStore())
    .environment(GlassyHostBrowser())
}
