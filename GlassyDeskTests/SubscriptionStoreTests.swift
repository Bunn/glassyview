import Foundation
import RevenueCat
import Testing
@testable import GlassyDesk

@MainActor
private final class SubscriptionClientStub: SubscriptionClient {
    enum Failure: Error { case offline }
    var isConfigured = true
    var cachedCustomerInfo: CustomerInfo?
    var info: CustomerInfo?
    var customerInfoRequests = 0
    var offeringsStarted = false
    var suspendOfferings = false
    private var offeringContinuation: CheckedContinuation<Offerings, Error>?
    let customerInfoStream: AsyncStream<CustomerInfo>
    let updates: AsyncStream<CustomerInfo>.Continuation

    init(cached: CustomerInfo? = nil, info: CustomerInfo? = nil) {
        cachedCustomerInfo = cached
        self.info = info
        (customerInfoStream, updates) = AsyncStream.makeStream()
    }

    func customerInfo() async throws -> CustomerInfo {
        customerInfoRequests += 1
        guard let info else { throw Failure.offline }
        return info
    }

    func offerings() async throws -> Offerings {
        offeringsStarted = true
        if suspendOfferings {
            return try await withCheckedThrowingContinuation { offeringContinuation = $0 }
        }
        throw Failure.offline
    }

    func finishOfferings() {
        suspendOfferings = false
        offeringContinuation?.resume(throwing: Failure.offline)
        offeringContinuation = nil
    }

    func purchase(_ package: Package) async throws -> SubscriptionPurchaseResult { throw Failure.offline }
    func restorePurchases() async throws -> CustomerInfo { try await customerInfo() }
}

@MainActor
@Suite("Subscription access resilience")
struct SubscriptionStoreTests {
    @Test("Cached Pro access is available before any product or network request")
    func cachedProAccessIsImmediate() async {
        let client = SubscriptionClientStub(cached: customerInfo(pro: true))
        let store = SubscriptionStore(client: client)
        #expect(store.hasProAccess)
        #expect(client.customerInfoRequests == 0)
        await store.refresh()
        #expect(store.hasProAccess)
        #expect(client.customerInfoRequests == 1)
    }

    @Test("An unavailable offering does not prevent customer information refresh")
    func failedOfferingsDoesNotPreventEntitlementRefresh() async {
        let client = SubscriptionClientStub(info: customerInfo(pro: true))
        let store = SubscriptionStore(client: client)
        await store.refresh()
        #expect(store.hasProAccess)
        #expect(client.customerInfoRequests == 1)
        #expect(!store.isRefreshing)
    }

    @Test("Slow product discovery does not delay paid entitlement updates")
    func slowOfferingsDoesNotBlockAccess() async {
        let client = SubscriptionClientStub(info: customerInfo(pro: true))
        client.suspendOfferings = true
        let store = SubscriptionStore(client: client)
        let refresh = Task { await store.refresh() }
        for _ in 0..<100 where !client.offeringsStarted || !store.hasProAccess {
            await Task.yield()
        }
        #expect(store.hasProAccess)
        #expect(store.isRefreshing)
        client.finishOfferings()
        await refresh.value
    }

    @Test("Authoritative loss of Pro access replaces the cached entitlement")
    func refreshedExpiredAccessReplacesCache() async {
        let client = SubscriptionClientStub(cached: customerInfo(pro: true), info: customerInfo(pro: false))
        let store = SubscriptionStore(client: client)
        #expect(store.hasProAccess)
        await store.refresh()
        #expect(!store.hasProAccess)
    }

    @Test("Restore reports whether an eligible purchase was found")
    func restoreReportsOutcome() async {
        let client = SubscriptionClientStub(info: customerInfo(pro: true))
        let store = SubscriptionStore(client: client)
        await store.restorePurchases()
        #expect(store.hasProAccess)
        #expect(store.isRestoreResultPresented)
        #expect(!store.restoreResultMessage.isEmpty)
    }

    private func customerInfo(pro: Bool) -> CustomerInfo {
        let entitlement = EntitlementInfo(
            identifier: SubscriptionStore.proEntitlementIdentifier,
            isActive: pro, willRenew: false, periodType: .normal,
            store: .appStore, productIdentifier: "dev.bunn.glassydesk.pro",
            isSandbox: true, ownershipType: .purchased
        )
        return CustomerInfo(
            entitlements: EntitlementInfos(entitlements: [SubscriptionStore.proEntitlementIdentifier: entitlement]),
            requestDate: .now, firstSeen: .now, originalAppUserId: "subscription-test"
        )
    }
}
