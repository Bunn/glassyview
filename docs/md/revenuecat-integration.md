# RevenueCat Integration

This app uses the RevenueCat Swift Package products `RevenueCat` and `RevenueCatUI` from:

`https://github.com/RevenueCat/purchases-ios-spm.git`

The project is configured with an `upToNextMajorVersion` requirement starting at `5.43.0`; `Package.resolved` currently pins `5.80.2`.

## Dashboard Setup

1. Use the `Glassy Desk` RevenueCat project and the `Glassy Desk (App Store)` app for bundle identifier `dev.bunn.glassydesk`.
2. The production App Store products are:
   - `dev.bunn.glassydesk.pro.monthly`: monthly subscription
   - `dev.bunn.glassydesk.pro.yearly`: yearly subscription
   - `dev.bunn.glassydesk.pro`: non-consumable lifetime unlock
   The separate Test Store products remain attached for development builds.
3. Keep the existing entitlement identifier `Glassy View Pro` for purchase compatibility.
4. Keep all three Test Store products and all three App Store products attached to `Glassy View Pro`.
5. Keep the `default` offering marked current.
6. The offering packages map to the matching Test Store and App Store products:
   - Monthly package -> monthly products
   - Annual package -> yearly products
   - Lifetime package -> lifetime products
7. Keep the RevenueCat Paywall attached to the default offering.
8. Enable Customer Center if your RevenueCat plan supports it.

If RevenueCat requires a different entitlement identifier, update `SubscriptionStore.proEntitlementIdentifier` to match exactly.

## App Configuration

The app reads the public SDK key from the `RevenueCatAPIKey` key in `Support/Info.plist`, which expands from the `REVENUECAT_API_KEY` build setting.

The build configurations use separate RevenueCat apps:

```text
Debug   -> Test Store public SDK key
Release -> App Store production public SDK key
```

## SwiftUI Entry Points

`DejaViewApp` configures RevenueCat once at launch, owns a `SubscriptionStore`, injects it into the SwiftUI environment, refreshes customer info, and listens for customer info updates:

```swift
@State private var subscriptionStore = SubscriptionStore()

init() {
    RevenueCatConfiguration.configure()
}

WindowGroup {
    ContentView()
        .environment(subscriptionStore)
        .task {
            await subscriptionStore.refresh()
            await subscriptionStore.observeCustomerInfoUpdates()
        }
}
```

`ContentView` exposes subscription actions from the More menu:

```swift
Button("Glassy Desk Pro", systemImage: proStatusSystemImage, action: presentSubscriptionManagement)
Button("Present Paywall", systemImage: "creditcard", action: presentRevenueCatPaywall)
Button("Customer Center", systemImage: "person.crop.circle", action: presentCustomerCenter)
```

## Entitlement Checking

Gate Pro-only app behavior with `subscriptionStore.hasProAccess`. Internally this checks RevenueCat customer info:

```swift
customerInfo?.entitlements[SubscriptionStore.proEntitlementIdentifier]?.isActive == true
```

Use entitlement state for access decisions rather than checking product identifiers directly. Product identifiers are still used to find packages for manual purchases.

## Purchases And Restore

Manual purchases use the current offering and RevenueCat's async package purchase API:

```swift
let result = try await Purchases.shared.purchase(package: package)

if !result.userCancelled {
    apply(result.customerInfo)
}
```

Restores are user-initiated:

```swift
let customerInfo = try await Purchases.shared.restorePurchases()
apply(customerInfo)
```

Errors are logged through `AppLog.subscriptions` and surfaced in `SubscriptionManagementView`.

## Paywall And Customer Center

The app presents RevenueCat Paywalls with:

```swift
PaywallView()
```

Customer Center is presented with:

```swift
CustomerCenterView()
```

Customer Center is most useful once the app has real subscriptions because it lets users restore purchases, manage subscriptions, request refunds on iOS, and change plans when configured in RevenueCat and App Store Connect.

## Best Practices

- Keep RevenueCat configured once, early in app launch.
- Keep release and development SDK keys separate.
- Use RevenueCat entitlements as the source of truth for Pro access.
- Use the current offering so product/order/paywall changes can happen remotely.
- Always provide a Restore Purchases path.
- Refresh customer info when entering purchase-sensitive flows.
- Replace the Test Store key before submitting to the App Store.

## Product Analytics

Glassy Desk records fixed RevenueCat funnel milestones alongside anonymous
Cloudflare aggregate events. The schema, privacy boundary, free-session usage
bands, and required Cloudflare Worker allowlist are documented in
[`analytics.md`](analytics.md).
