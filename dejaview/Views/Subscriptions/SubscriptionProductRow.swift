import RevenueCat
import SwiftUI

struct SubscriptionProductRow: View {
    let productID: SubscriptionProductID
    let package: Package?
    let isPurchasing: Bool
    let purchase: () -> Void

    var body: some View {
        LabeledContent {
            Button(purchaseButtonTitle, systemImage: "cart", action: purchase)
                .disabled(package == nil || isPurchasing)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(package?.storeProduct.localizedTitle ?? productID.displayName)
                    .font(.headline)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var purchaseButtonTitle: String {
        guard let package else { return String(localized: "Unavailable") }
        return package.storeProduct.localizedPriceString
    }

    private var description: String {
        guard let package else { return String(localized: "Missing from the current offering.") }

        let product = package.storeProduct
        if product.localizedDescription.isEmpty {
            return productID.fallbackDescription
        }

        return product.localizedDescription
    }
}
