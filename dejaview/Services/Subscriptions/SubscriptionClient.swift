import RevenueCat

@MainActor
protocol SubscriptionClient {
    var isConfigured: Bool { get }
    var cachedCustomerInfo: CustomerInfo? { get }
    var customerInfoStream: AsyncStream<CustomerInfo> { get }
    func customerInfo() async throws -> CustomerInfo
    func offerings() async throws -> Offerings
    func purchase(_ package: Package) async throws -> SubscriptionPurchaseResult
    func restorePurchases() async throws -> CustomerInfo
}

struct SubscriptionPurchaseResult {
    let customerInfo: CustomerInfo
    let userCancelled: Bool
}

struct RevenueCatSubscriptionClient: SubscriptionClient {
    var isConfigured: Bool { Purchases.isConfigured }
    var cachedCustomerInfo: CustomerInfo? {
        guard isConfigured else { return nil }
        return Purchases.shared.cachedCustomerInfo
    }
    var customerInfoStream: AsyncStream<CustomerInfo> {
        Purchases.shared.customerInfoStream
    }

    func customerInfo() async throws -> CustomerInfo {
        try await Purchases.shared.customerInfo()
    }

    func offerings() async throws -> Offerings {
        try await Purchases.shared.offerings()
    }

    func purchase(_ package: Package) async throws -> SubscriptionPurchaseResult {
        let result = try await Purchases.shared.purchase(package: package)
        return SubscriptionPurchaseResult(customerInfo: result.customerInfo,
                                          userCancelled: result.userCancelled)
    }

    func restorePurchases() async throws -> CustomerInfo {
        try await Purchases.shared.restorePurchases()
    }
}
