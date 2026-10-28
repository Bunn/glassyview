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
    /// Product identifiers whose introductory offer this customer can redeem.
    private(set) var introOfferEligibleProductIDs: Set<String> = []
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

    /// Fetches products again even while a wider refresh is still waiting on the network.
    func reloadOfferings() async {
        guard isConfigured else { return }
        await refreshOfferings()
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
            await refreshIntroOfferEligibility()
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
        if case .failed(let error) = await purchaseOutcome(for: package) {
            present(error)
        }
    }

    /// Purchases without presenting errors, so a paywall can report them in place.
    func purchaseOutcome(for package: Package) async -> SubscriptionPurchaseOutcome {
        guard client.isConfigured else { return .failed(ErrorCode.configurationError as NSError) }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await client.purchase(package)
            guard !result.userCancelled else { return .cancelled }

            apply(result.customerInfo)
            return .purchased
        } catch where ErrorCode(rawValue: (error as NSError).code) == .purchaseCancelledError {
            return .cancelled
        } catch {
            AppLog.subscriptions.error("RevenueCat purchase failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error as NSError)
        }
    }

    func restorePurchases() async {
        guard isConfigured else { return }
        switch await restoreOutcome() {
        case .restored, .nothingToRestore:
            restoreResultMessage = hasProAccess
                ? String(localized: "Your Glassy Desk Pro access has been restored.")
                : String(localized: "No active Glassy Desk Pro purchase was found. Check that you’re using the Apple Account used for your purchase.")
            isRestoreResultPresented = true
        case .failed(let error):
            present(error)
        }
    }

    /// Restores without presenting the result, so a paywall can report it in place.
    func restoreOutcome() async -> SubscriptionRestoreOutcome {
        guard client.isConfigured else { return .failed(ErrorCode.configurationError as NSError) }

        isRestoring = true
        defer { isRestoring = false }

        do {
            apply(try await client.restorePurchases())
            return hasProAccess ? .restored : .nothingToRestore
        } catch {
            AppLog.subscriptions.error("RevenueCat restore failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error as NSError)
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

    private func refreshIntroOfferEligibility() async {
        let packages = currentOffering?.availablePackages.filter {
            $0.storeProduct.introductoryDiscount != nil
        } ?? []
        guard !packages.isEmpty else {
            introOfferEligibleProductIDs = []
            return
        }

        let eligibility = await client.introOfferEligibility(for: packages)
        introOfferEligibleProductIDs = Set(eligibility.compactMap { productID, isEligible in
            isEligible ? productID : nil
        })
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

enum SubscriptionPurchaseOutcome {
    case purchased
    case cancelled
    case failed(NSError)
}

enum SubscriptionRestoreOutcome {
    case restored
    case nothingToRestore
    case failed(NSError)
}
