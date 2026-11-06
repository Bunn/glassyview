# What's New and the review screen

After a major update, Glassy Desk shows what's new, then asks for a rating on its own screen. The approach comes from [Cristian Rus's post on how Left collected its reviews](https://x.com/CristianRus4/status/2115308205358325936): ask only after a major update, right after good news, and never during use.

## Who sees what

| Person | What's New | Review screen |
| --- | --- | --- |
| Updated to a new announced release, paying, has a saved or recent Mac | Yes | Yes, unless in the cooldown |
| Updated to a new announced release, paying, has no saved or recent Mac | Yes | No, because there's nothing to rate yet |
| Updated to a new announced release, on the free tier or a free trial | Yes | No |
| New install finishing onboarding | No, until the next announced release | No |

Paying means an active Pro entitlement that isn't in a free trial, as reported by `SubscriptionStore.isPayingCustomer`. Someone who subscribes after a release was announced isn't asked until the next announced release.

Both screens appear at most once per announced release, even if they're closed straight away. They wait until the app is idle on launch or on returning to it. If a session, sheet, alert, or a widget or Siri request is in progress, or the subscription status hasn't loaded yet, the announcement waits for the next launch or return. It never follows a session ending, so a dropped connection or a free-session limit can't lead straight into a request for a rating.

## Announcing a release

Add the release to the top of `WhatsNewRelease.all` in [ReleaseAnnouncement.swift](../../dejaview/Services/ReleaseAnnouncements/ReleaseAnnouncement.swift), with its version as the `id` and its features, and add the translations to `Localizable.xcstrings`. The first entry is the one announced after launch. Keep this to a few big releases a year. A new App Store version on its own doesn't show anything, and bug-fix releases stay out of the list.

## What's New in Settings

**Settings > About > What's New** lists every release in `WhatsNewRelease.all`, newest first, with the same features and footnotes as the launch screen. The list goes back to 1.2, written from the App Store release notes. Reading it doesn't mark a release as announced, so it never skips the launch screen or the review screen that follows it.

## The review screen

- **Rate Glassy Desk** calls StoreKit's `requestReview`. The button then becomes **Write a Review**, which opens the App Store's written review page. Closing the screen is always fine.
- StoreKit doesn't report whether its prompt appeared or whether someone rated, and it shows at most three prompts a year. Tapping **Rate Glassy Desk** therefore starts a 365-day cooldown for the review screen. What's New keeps appearing during the cooldown.
- StoreKit shows no prompt in TestFlight, and shows one in development builds that can't submit a rating.
- **Send Feedback** is always offered next to the rating. Nothing asks how someone feels first, so the screen doesn't steer unhappy people away from rating. The screen itself is limited to paying customers. Anyone else can still rate on the App Store, but the app doesn't ask them to.
- The copy doesn't ask for five stars.

## Adding real reviews

The carousel stays hidden until `AppReviewTestimonial.published` has entries. Add only reviews published on the App Store, quoted verbatim, with the author's App Store name. Don't add invented or paraphrased quotes, user counts, or ratings.

## Trying it

Launch a debug build with `-whatsNewPreview 1` to open the flow directly, or `-whatsNewPreview testimonials` to check the carousel with placeholder text that's compiled out of release builds.

To try the real path, set `hasCompletedOnboarding` to true and leave `releaseAnnouncement.lastAnnouncedRelease` unset. The review screen also needs a saved or recent Mac and a paid Pro entitlement, such as a sandbox purchase, so `-whatsNewPreview` is the quicker way to check its layout.

## Analytics

The events and the `whats_new` source are listed in [analytics.md](analytics.md). The Worker rejects a whole batch if it contains an unknown event, so deploy the Worker change before releasing the app.
