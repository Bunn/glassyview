import Foundation
import Observation
import RevenueCat

@MainActor
@Observable
final class SubscriptionStore {
    static let proEntitlementIdentifier = "Glassy View Pro"

    private(set) var customerInfo: CustomerInfo?
    private(set) var offerings: Offerings?
    private(set) var currentOffering: Offering?
    private(set) var isRefreshing = false
    private(set) var isPurchasing = false
    private(set) var isRestoring = false

    var isErrorPresented = false
    var errorMessage = ""

    var hasProAccess: Bool {
        proEntitlement?.isActive == true
    }

    var proEntitlement: EntitlementInfo? {
        customerInfo?.entitlements[Self.proEntitlementIdentifier]
    }

    var activeProductIdentifier: String? {
        proEntitlement?.productIdentifier
    }

    var proExpirationDate: Date? {
        proEntitlement?.expirationDate
    }

    var managementURL: URL? {
        customerInfo?.managementURL
    }

    func package(for productID: SubscriptionProductID) -> Package? {
        currentOffering?.availablePackages.first { package in
            package.storeProduct.productIdentifier == productID.rawValue ||
            productID.packageIdentifierCandidates.contains(package.identifier)
        }
    }

    func refresh() async {
        guard isConfigured else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let offerings = try await Purchases.shared.offerings()
            apply(offerings)

            let customerInfo = try await Purchases.shared.customerInfo()
            apply(customerInfo)
        } catch {
            present(error)
        }
    }

    func purchase(_ productID: SubscriptionProductID) async {
        guard let package = package(for: productID) else {
            present(message: String(localized: "\(productID.displayName) is not available in the current RevenueCat offering."))
            return
        }

        await purchase(package)
    }

    func purchase(_ package: Package) async {
        guard isConfigured else { return }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await Purchases.shared.purchase(package: package)
            guard !result.userCancelled else { return }

            apply(result.customerInfo)
        } catch {
            present(error)
        }
    }

    func restorePurchases() async {
        guard isConfigured else { return }

        isRestoring = true
        defer { isRestoring = false }

        do {
            let customerInfo = try await Purchases.shared.restorePurchases()
            apply(customerInfo)
        } catch {
            present(error)
        }
    }

    func observeCustomerInfoUpdates() async {
        guard isConfigured else { return }

        for await customerInfo in Purchases.shared.customerInfoStream {
            apply(customerInfo)
        }
    }

    func apply(_ customerInfo: CustomerInfo) {
        self.customerInfo = customerInfo
        AppLog.subscriptions.info("Updated customer info; proActive=\(self.hasProAccess, privacy: .public)")
    }

    private var isConfigured: Bool {
        guard Purchases.isConfigured else {
            present(message: String(localized: "RevenueCat is not configured. Set the RevenueCatAPIKey Info.plist value before using purchases."))
            return false
        }

        return true
    }

    private func apply(_ offerings: Offerings) {
        self.offerings = offerings
        currentOffering = offerings.current
        AppLog.subscriptions.info("Updated RevenueCat offerings; hasCurrent=\((offerings.current != nil), privacy: .public)")
    }

    private func present(_ error: Error) {
        AppLog.subscriptions.error("RevenueCat operation failed: \(error.localizedDescription, privacy: .public)")
        present(message: error.localizedDescription)
    }

    private func present(message: String) {
        errorMessage = message
        isErrorPresented = true
    }
}
