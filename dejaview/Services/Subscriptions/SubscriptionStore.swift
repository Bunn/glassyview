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
    var isRestoreResultPresented = false
    private(set) var restoreResultMessage = ""

    @ObservationIgnored private let client: any SubscriptionClient

    init(client: any SubscriptionClient = RevenueCatSubscriptionClient()) {
        self.client = client
        applyCachedCustomerInfo()
    }

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
        guard isConfigured, !isRefreshing else { return }

        applyCachedCustomerInfo()
        isRefreshing = true
        defer { isRefreshing = false }

        // Product discovery must not delay access to an existing purchase.
        async let customerUpdate: Void = refreshCustomerInfo()
        async let productUpdate: Void = refreshOfferings()
        _ = await (customerUpdate, productUpdate)
    }

    func applyCachedCustomerInfo() {
        guard client.isConfigured, customerInfo == nil,
              let cachedCustomerInfo = client.cachedCustomerInfo else { return }
        apply(cachedCustomerInfo)
    }

    private func refreshCustomerInfo() async {
        do {
            apply(try await client.customerInfo())
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    private func refreshOfferings() async {
        do {
            apply(try await client.offerings())
        } catch is CancellationError {
            return
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
            let result = try await client.purchase(package)
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
            let customerInfo = try await client.restorePurchases()
            apply(customerInfo)
            restoreResultMessage = hasProAccess
                ? String(localized: "Your Glassy Desk Pro access has been restored.")
                : String(localized: "No active Glassy Desk Pro purchase was found. Check that you’re using the Apple Account used for your purchase.")
            isRestoreResultPresented = true
        } catch {
            present(error)
        }
    }

    func observeCustomerInfoUpdates() async {
        guard isConfigured else { return }

        applyCachedCustomerInfo()
        for await customerInfo in client.customerInfoStream {
            guard !Task.isCancelled else { return }
            apply(customerInfo)
        }
    }

    func apply(_ customerInfo: CustomerInfo) {
        self.customerInfo = customerInfo
        AppLog.subscriptions.info("Updated customer info; proActive=\(self.hasProAccess, privacy: .public)")
    }

    private var isConfigured: Bool {
        guard client.isConfigured else {
            present(message: String(localized: "Purchases are temporarily unavailable. Please try again later."))
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
