import SwiftUI

struct SubscriptionManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionStore.self) private var subscriptionStore

    @State private var isPaywallPresented = false
    @State private var isCustomerCenterPresented = false

    var body: some View {
        @Bindable var subscriptionStore = subscriptionStore

        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Access") {
                        Label(accessText, systemImage: accessSystemImage)
                    }

                    if let productIdentifier = subscriptionStore.activeProductIdentifier {
                        LabeledContent("Product", value: productIdentifier)
                    }

                    if let expirationDate = subscriptionStore.proExpirationDate {
                        LabeledContent("Renews or Expires") {
                            Text(expirationDate, format: .dateTime.year().month().day())
                        }
                    }
                }

                Section("Products") {
                    ForEach(SubscriptionProductID.allCases) { productID in
                        SubscriptionProductRow(productID: productID,
                                               package: subscriptionStore.package(for: productID),
                                               isPurchasing: subscriptionStore.isPurchasing) {
                            Task {
                                await subscriptionStore.purchase(productID)
                            }
                        }
                    }
                }

                Section {
                    Button("Present Paywall", systemImage: "creditcard", action: presentPaywall)

                    Button("Restore Purchases", systemImage: "arrow.clockwise", action: restorePurchases)
                        .disabled(subscriptionStore.isRestoring)

                    Button("Customer Center", systemImage: "person.crop.circle", action: presentCustomerCenter)
                }

                if let managementURL = subscriptionStore.managementURL {
                    Section {
                        Link(destination: managementURL) {
                            Label("Manage Subscription", systemImage: "link")
                        }
                    }
                }
            }
            .navigationTitle("Glassy Desk Pro")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
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
            .sheet(isPresented: $isCustomerCenterPresented) {
                RevenueCatCustomerCenterSheet()
            }
        }
    }

    private var accessText: String {
        subscriptionStore.hasProAccess
            ? String(localized: "Glassy Desk Pro")
            : String(localized: "Free")
    }

    private var accessSystemImage: String {
        subscriptionStore.hasProAccess ? "checkmark.seal.fill" : "seal"
    }

    private func presentPaywall() {
        isPaywallPresented = true
    }

    private func presentCustomerCenter() {
        isCustomerCenterPresented = true
    }

    private func restorePurchases() {
        Task {
            await subscriptionStore.restorePurchases()
        }
    }
}

#Preview {
    SubscriptionManagementView()
        .environment(SubscriptionStore())
}
