import RevenueCat
import RevenueCatUI
import SwiftUI

struct RevenueCatPaywallSheet: View {
    @Environment(SubscriptionStore.self) private var subscriptionStore

    private let onProAccessGranted: (@MainActor @Sendable () -> Void)?

    init(onProAccessGranted: (@MainActor @Sendable () -> Void)? = nil) {
        self.onProAccessGranted = onProAccessGranted
    }

    var body: some View {
        Group {
            if Purchases.isConfigured {
                PaywallView()
                    // Match the compact layout configured in RevenueCat's phone preview.
                    .environment(\.horizontalSizeClass, .compact)
                    .onPurchaseCompleted { customerInfo in
                        handle(customerInfo)
                    }
                    .onRestoreCompleted { customerInfo in
                        handle(customerInfo)
                    }
                    .task {
                        await subscriptionStore.refresh()
                    }
            } else {
                RevenueCatUnavailableView()
            }
        }
        // The default iPad form sheet is too short for this full-height paywall.
        .presentationSizing(.page)
    }

    private func handle(_ customerInfo: CustomerInfo) {
        subscriptionStore.apply(customerInfo)

        if subscriptionStore.hasProAccess {
            onProAccessGranted?()
        }
    }
}
