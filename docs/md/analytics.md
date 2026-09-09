# Privacy-Preserving Product Analytics

Glassy Desk measures the activation and purchase funnel with the same two-layer
approach used by BreadCount:

1. Identifier-free aggregate events are sent to the Cloudflare app analytics
   Worker.
2. Fixed, privacy-safe milestones are written to the existing anonymous
   RevenueCat customer so behavior can be related to later conversion.

Optional analytics is enabled by default and can be changed in Settings with
**Share Optional Analytics**. Existing saved choices are preserved.
Disabling it cancels in-flight aggregate uploads, drops queued events immediately,
clears local funnel state, and requests removal of optional RevenueCat attributes
on the SDK’s next sync.
No final opt-out analytics event is sent. Data already received by a server
cannot be recalled. RevenueCat purchase verification and transaction history
continue independently of this optional setting.

## What this answers

| Product question | Signal |
| --- | --- |
| Do activation and conversion differ between iPhone and iPad? | Every Cloudflare event grouped by `deviceClass` |
| Do people reach the product's value? | `remote_session_connected` compared with `app_opened` and `onboarding_completed` |
| Are sessions using Standard VNC or Fast Connection? | `remote_session_connected` grouped by `context.sessionType`: `vnc` or `glassy_stream` |
| Do free users return for another timed session? | `free_session_restarted` and RevenueCat attribute `gv_free_session_band` |
| Are people deliberately resetting the one-minute allowance? | `free_session_restarted_after_limit` and milestone `gv_ms_refresh_after_limit` |
| Which upgrade prompt works best? | `paywall_presented` grouped by `settings`, `free_session_timer`, `free_session_cooldown`, or historical `session_limit` |
| Does the cooldown screen lead to Pro? | Cooldown views and upgrade taps, then paywall and purchase events with `source: free_session_cooldown` |
| Do people reject the offer before trying to buy? | `paywall_dismissed / paywall_presented` |
| Do they show intent but abandon Apple's purchase sheet? | `purchase_cancelled / purchase_started` |
| Is billing infrastructure blocking conversion? | `purchase_failed`, grouped by its sanitized reason |
| Does the funnel ultimately convert? | `purchase_completed` plus RevenueCat's authoritative transaction data |

Cloudflare event counts are aggregate actions, not unique people. Use the
RevenueCat milestones and current `gv_free_session_band` to understand how many
anonymous customers repeatedly use free mode. The band values are deliberately
coarse: `1`, `2`, `3_5`, `6_10`, and `11_plus`.

## Cooldown conversion

The 30-second cooldown screen has its own `free_session_cooldown` source. It
records `free_session_cooldown_viewed` once per cooldown during a session-screen
visit, even if the paywall is reopened or the app returns from the background.
A later cooldown or a new visit to a restored cooldown records another view.
Each **Explore Pro** tap records `free_session_cooldown_upgrade_tapped`.
Both events include the coarse `sessionType`; the cooldown deadline stays local.

The paywall carries this source through presentation, dismissal, purchase, and
restore outcomes. Existing `free_session_timer` events still represent the timer
control inside an active free session. Historical `session_limit` events remain
separate and are never treated as cooldown views.

The Worker's local dashboard shows five stages: cooldown view, Explore Pro tap,
paywall view, purchase attempt, and successful Pro unlock. Only
`purchase_completed` with `outcome: success` counts as an unlock; restores and
unavailable outcomes do not. Each stage follows the selected date, device, and
version filters and reports actions relative to screen views. These are aggregate
ratios, not conversion rates for unique people or matched journeys. Repeated
actions or delivery retries can exceed 100%, and purchase callbacks can include
sandbox purchases.

RevenueCat records fixed first-occurrence milestones for the cooldown view,
upgrade tap, and cooldown paywall so this entry point can also be related to
later conversion on the existing anonymous customer profile.

## Cloudflare payload

The app posts batches to:

```text
POST https://analytics.bunn.dev/v1/events
```

Each request contains only `{ "events": [...] }`. Each event contains only:

```json
{
  "schemaVersion": 1,
  "event": "paywall_dismissed",
  "app": "glassydesk",
  "platform": "ios",
  "deviceClass": "ipad",
  "appVersion": "1.0",
  "build": "1",
  "osMajor": 26,
  "context": {
    "source": "session_limit",
    "outcome": "cancelled"
  }
}
```

There are no timestamps, installation IDs, RevenueCat IDs, user IDs, machine
IDs, hostnames, IP addresses, credentials, connection durations, or remote
session content. `deviceClass` is limited to the coarse allowlist `iphone`,
`ipad`, or `other`; it does not include the hardware model. The Worker supplies
its own receive timestamp. The
`X-Analytics-Token` header is generated again for every upload and is used only
as a rate-limit partition, so it cannot correlate requests from one install.

Uploads use an ephemeral URL session with cookies and caching disabled. The
in-memory queue is capped at 200 sanitized events, requests are capped at 50
events and 64 KiB, retryable failures use bounded backoff, and analytics never
blocks product behavior.

Debug builds write analytics diagnostics to the unified logging system under
the `Analytics` category. These messages contain only allowlisted event names,
coarse context values, device class, queue and batch counts, and delivery
outcomes. Failed deliveries also include the HTTP status or the transport error
domain and numeric code. They never include request bodies, rate-limit tokens,
identifiers, localized error text, or response bodies. The analytics logger and
every call site are excluded from non-debug builds with `#if DEBUG`.

## Event allowlist

The Cloudflare Worker must allow app value `glassydesk` and these events:

```text
app_opened
onboarding_completed
remote_session_connected
free_session_started
free_session_restarted
free_session_restarted_after_limit
free_session_timer_opened
free_session_limit_reached
free_session_cooldown_viewed
free_session_cooldown_upgrade_tapped
paywall_presented
paywall_dismissed
purchase_started
purchase_completed
purchase_cancelled
purchase_failed
restore_started
restore_completed
restore_failed
```

The Worker must also accept the top-level `deviceClass` field with only these
values:

```text
iphone, ipad, other
```

Require `deviceClass` for `app == "glassydesk"`; keep it optional for older apps
such as BreadCount so this additive schema change does not reject their current
payloads. Add it to the Analytics Engine field mapping and reporting queries so
funnels can be grouped by device class. Unknown values should continue to fail
strict schema validation.

Allowed context values used by Glassy Desk are:

```text
source:  app, onboarding, settings, free_session_timer, free_session_cooldown,
         session_limit, unknown
outcome: success, failure, cancelled, unavailable
reason:  network, store_unavailable, purchase_not_allowed, payment_pending,
         configuration, unknown
sessionType: vnc, glassy_stream
```

`sessionType` is supplied on successful connections and the free-session start,
restart, timer-open, limit, and cooldown events. It describes the connection method:
`vnc` means Standard VNC and `glassy_stream` means Fast Connection with Glassy Desk
for Mac. It contains no session or machine identifier. The field is optional so
older releases remain compatible; missing values must be reported separately as
unreported, never inferred as VNC. These are session counts, not unique users.
The Worker accepts this field only for Glassy Desk and stores it in that app's
Analytics Engine `blob11`. Deploy the updated Worker before distributing an app
release that sends this field, because the older strict validator rejects it.
The cooldown events and source also require the compatible Worker allowlists
before app distribution. They reuse the existing storage fields, so no D1
migration is required.

The production health endpoint currently reports
`{"status":"ok","service":"app-analytics","version":1}`. The Worker source is
in the sibling `../worker-apps-analytics` project. Deploy its strict
app/event/context allowlists and register `glassydesk` in the production D1
`apps` table before enabling this in a production release.

## RevenueCat attributes

Milestones are fixed keys whose value is always `1`; they cannot carry dynamic
user data:

```text
gv_ms_onboarding_completed
gv_ms_first_session_connected
gv_ms_first_free_session
gv_ms_free_session_restarted
gv_ms_refresh_after_limit
gv_ms_free_limit_reached
gv_ms_free_timer_upgrade_tapped
gv_ms_cooldown_viewed
gv_ms_cooldown_upgrade_tapped
gv_ms_paywall_settings
gv_ms_paywall_free_timer
gv_ms_paywall_session_limit
gv_ms_paywall_cooldown
gv_ms_purchase_started
gv_ms_purchase_completed
gv_ms_purchase_cancelled
gv_ms_purchase_failed
```

`gv_free_session_band` is the only changing attribute and accepts only the five
fixed coarse values listed above. RevenueCat already owns the anonymous
customer identity needed for purchase verification; no RevenueCat identifier is
copied into Cloudflare events.

## Source locations

- Event schema and preference: `dejaview/Services/Analytics/AnalyticsTracking.swift`
- Cloudflare delivery: `dejaview/Services/Analytics/CloudflareAnalytics.swift`
- RevenueCat milestones and free-session bands:
  `dejaview/Services/Analytics/FunnelMilestoneTracking.swift`
- Free-session instrumentation: `dejaview/Views/Session/SessionView.swift`
- Cooldown view deduplication and upgrade actions:
  `dejaview/Services/Analytics/FreeSessionCooldownTracking.swift`
- Paywall and billing outcomes:
  `dejaview/Views/Subscriptions/RevenueCatPaywallSheet.swift`
- Tests: `GlassyDeskTests/AnalyticsTests.swift`,
  `GlassyDeskTests/FunnelMilestoneTrackingTests.swift`, and
  `GlassyDeskTests/FreeSessionCooldownTrackingTests.swift`
