import Foundation
import RevenueCat

/// One purchasable option on the paywall, with prices and offers read from RevenueCat.
struct PaywallPlan: Identifiable {
    enum Kind: Int, CaseIterable {
        case monthly
        case yearly
        case lifetime
    }

    let kind: Kind
    let package: Package
    /// The share saved against paying monthly for a year, when worth showing.
    let savings: Double?
    /// How long the free trial lasts, when this customer can still start one.
    let freeTrialPeriod: String?

    var id: Kind { kind }
    var price: String { package.storeProduct.localizedPriceString }
    var pricePerMonth: String? { package.storeProduct.localizedPricePerMonth }

    var title: String {
        switch kind {
        case .yearly: SubscriptionProductID.yearly.displayName
        case .monthly: SubscriptionProductID.monthly.displayName
        case .lifetime: SubscriptionProductID.lifetime.displayName
        }
    }

    /// Plans in display order, with yearly, the default choice, in the middle.
    static func plans(in offering: Offering?, introOfferEligibleProductIDs: Set<String>) -> [PaywallPlan] {
        guard let offering else { return [] }

        let packages = Dictionary(
            Kind.allCases.compactMap { kind in package(for: kind, in: offering).map { (kind, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let monthlyPrice = packages[.monthly]?.storeProduct.price

        return Kind.allCases.compactMap { kind in
            guard let package = packages[kind] else { return nil }

            var savings: Double?
            if kind == .yearly, let monthlyPrice, monthlyPrice > 0 {
                let yearlyPrice = package.storeProduct.price
                let fraction = 1 - NSDecimalNumber(decimal: yearlyPrice / (monthlyPrice * 12)).doubleValue
                // Round down to whole percent so the claim is never overstated.
                let wholePercent = (fraction * 100).rounded(.down) / 100
                savings = wholePercent >= 0.05 ? wholePercent : nil
            }

            let product = package.storeProduct
            let isEligible = introOfferEligibleProductIDs.contains(product.productIdentifier)
            let trial = product.introductoryDiscount.flatMap { discount in
                isEligible && discount.paymentMode == .freeTrial ? discount.subscriptionPeriod : nil
            }

            return PaywallPlan(kind: kind,
                               package: package,
                               savings: savings,
                               freeTrialPeriod: trial.map(Self.describe))
        }
    }

    private static func package(for kind: Kind, in offering: Offering) -> Package? {
        switch kind {
        case .yearly: offering.annual ?? matching(.yearly, in: offering)
        case .monthly: offering.monthly ?? matching(.monthly, in: offering)
        case .lifetime: offering.lifetime ?? matching(.lifetime, in: offering)
        }
    }

    private static func matching(_ productID: SubscriptionProductID, in offering: Offering) -> Package? {
        offering.availablePackages.first { package in
            package.storeProduct.productIdentifier == productID.rawValue ||
            productID.packageIdentifierCandidates.contains(package.identifier)
        }
    }

    /// "1 week", "3 days", "1 month" in the customer's language.
    private static func describe(_ period: SubscriptionPeriod) -> String {
        var components = DateComponents()
        switch period.unit {
        case .day: components.day = period.value
        case .week: components.weekOfMonth = period.value
        case .month: components.month = period.value
        case .year: components.year = period.value
        }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .weekOfMonth, .month, .year]
        return formatter.string(from: components) ?? ""
    }
}
