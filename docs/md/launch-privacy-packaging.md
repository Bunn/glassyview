# Release privacy and attribution validation

The app embeds `dejaview/PrivacyInfo.xcprivacy` and the widget embeds
`GlassyDeskWidgets/PrivacyInfo.xcprivacy` through their existing synchronized
Xcode target folders. No entitlement, iCloud configuration or SwiftData schema
changes are part of these privacy fixes.

- First-party app defaults use CA92.1. The widget snapshot uses an App Group
  file, not shared UserDefaults, so 1C8F.1 is not declared speculatively.
- App monotonic time is used to measure frame publication intervals (35F9.1).
- The app declares purchase history, the RevenueCat anonymous customer
  identifier, and optional product interaction as linked data; none is used for
  cross-app advertising tracking. Cloudflare payloads remain identifier-free,
  while RevenueCat milestones are customer-linked.
- Optional collection is off by default under a new consent key. Stopping
  collection cancels aggregate uploads and requests removal of the fixed
  optional RevenueCat attributes; transaction records are retained for access.
- `dejaview/Resources/ThirdPartyNotices.txt` bundles full notices for RoyalVNCKit,
  CryptoSwift, RevenueCat/RevenueCatUI, zlib and D3DES. Open them from About.
- Unassigned legacy icon renditions are retained in `docs/assets/legacy-app-icons`
  instead of the compiled AppIcon set.

The matching policy has been published from the website repository at
`glassydesk/privacy.html`, dated September 7, 2026. It describes the Mac
companion, pairing camera, permissions, optional analytics, ordinary network
request metadata, and opt-out behavior. Existing iCloud and saved-password
paragraphs are unchanged. The policy distinguishes version 1.3 controls from earlier iOS behavior.
Updating App Store Connect privacy answers remains a separate release action; an app manifest does not update
the App Store listing.

Sources checked September 7, 2026:

- [Apple required-reason API declarations](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [Apple collected-data declarations](https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest)
- [RevenueCat attribute removal and synchronization](https://www.revenuecat.com/docs/customers/customer-attributes)
