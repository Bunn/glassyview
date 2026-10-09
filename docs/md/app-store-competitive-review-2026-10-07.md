# Competitive review: Screens 5 vs Glassy Desk — 7 October 2026

A comparison of the [Screens 5 App Store listing](https://apps.apple.com/us/app/screens-5-vnc-remote-desktop/id1663047912) (description and all 10 iPad screenshots) with the [live Glassy Desk listing](https://apps.apple.com/us/app/glassy-desk/id6787767486) (version 2.3), the en-US metadata in `.asc/metadata`, and the current source on `duo` (`456f58a`).

**Summary:** Glassy Desk's technology is ahead of Screens in places that matter, but the listing doesn't sell it, and three features are missing that the "headless Mac mini" story depends on.

## What Screens does well

- **It sells use cases, not protocols.** The first paragraph of the description says: *"a remote workstation, a headless Mac mini, or helping friends and family."* A later section adds *"Monitor long-running tasks from anywhere."* People find an app by searching for a situation they're in, not by searching "VNC."
- **Each screenshot shows one idea:** one headline, one subline and a large device frame. All 10 slots are used, in this order:
  1. Fast, fluid connections from everywhere
  2. Control Macs, PCs and more
  3. Type on your computer by speaking (dictation)
  4. Keep connections safe and private
  5. Hide your Mac desktop with Curtain Mode
  6. Drag and drop files between your iPad and Mac
  7. Switch between multiple Mac displays
  8. Your iPad, supercharged (multiple windows, multitasking)
  9. Full support for keyboard, pointing devices and Pencil
  10. Share sessions with other Mac users
- **The "What's New" text lists real features** (Siri, Quick Connect widget, drag gestures), so even the update notes help sell the app.

Screens' pricing for reference: $3.99/month, $29.99/year, $199.99 lifetime, with a 7-day free trial. Glassy Desk: $1.99/month, $19.99/year, $29.99 lifetime.

## App Store changes

### Screenshots

The live set is 5 portrait images, each labeled "iPad".

1. **Use all 10 slots.** Only 5 are filled.
2. **Cut the text on each image in half.** Each one has an eyebrow, headline, subline, footer headline and footer subline. At search-result size only the headline can be read, so drop the footer block and make the device frame bigger.
3. **Show results, not forms.** Screenshot 3 is a login form and screenshot 2 is the pairing setup screen. Neither shows what the user gets.
4. **Make a separate iPhone set,** and an iPhone Duo set now that `3161b6d` adds Duo support. Today iPhone shoppers see iPad screenshots.
5. **Vary what's on the remote screen.** "Coastal retreat" appears in 3 of the 5 shots. Show real work instead: an Xcode build, a terminal running an AI agent, Activity Monitor, a render.

Suggested order (the first 3 show up in search results):

| # | Headline |
|---|---|
| 1 | Your Mac, from anywhere |
| 2 | Headless Mac mini? No problem |
| 3 | Up to 4K at 60 FPS, encrypted (Glassy Stream) |
| 4 | Real keys and shortcuts |
| 5 | Your iPad as the controller on a big screen |
| 6 | Wake your Mac, then connect |
| 7 | Connect with Siri, widgets and Shortcuts |
| 8 | Paste from iPhone to Mac |
| 9 | Private by design: no cloud relay |
| 10 | Pay once. No subscription required |

### Metadata

Current en-US values are in `.asc/metadata/app-info/en-US.json` and `.asc/metadata/version/1.1/en-US.json`.

- **Name:** "Glassy Desk" contains no search terms. "Glassy Desk: Remote Desktop" is 27 of 30 characters. Screens' name includes "VNC Remote Desktop."
- **Subtitle:** "Mac & Mac mini Remote Control" (29 characters) targets the headless-mini searches. Current: "Fast Remote Access for Mac".
- **Keywords:** Apple already indexes words from the name and subtitle, so "remote," "Mac" and "control" in the keyword field are wasted. A replacement that fits (97 of 100 characters):

  ```
  vnc,screen,sharing,headless,server,studio,viewer,wake,lan,keyboard,trackpad,mouse,access,ai,build
  ```

- **Description:** start with use cases, e.g. *"Reach a headless Mac mini, a Mac Studio in the closet, or your build machine. Check on long builds, renders and AI agents from your phone."* Then give concrete specs: hardware H.264, up to 4K60, adaptive quality, end-to-end encryption, free Mac companion, no account required.
- **Pricing as a selling point:** the $29.99 lifetime price vs Screens' $199.99. Say it in the description and on a screenshot.
- **What's New:** the text is still "Bug fixes and improvements." Duo support is the next release's headline.
- **Mac availability:** the listing shows "Designed for iPad / Not verified for macOS." Either verify it or remove Mac availability, because an unverified iPad app on a Mac weakens the listing.
- **Privacy labels:** the live label shows only Purchase History. Opt-in analytics through Cloudflare and RevenueCat milestones probably also need disclosing; [launch hardening](launch-hardening-2026-09-07.md) already lists App Store privacy answers as unverified.
- **Ratings:** the app has 1 rating, and there is no `requestReview` call in the source. Ask for a review after about the third successful session longer than 2 minutes.
- **Other App Store tools:** add Custom Product Pages (one for "headless Mac mini," one for "Mac Studio / creative"), test screenshot sets with Product Page Optimization, and promote the Lifetime purchase on the product page.

### Free tier

Free sessions are 60 seconds with a 30-second cooldown ([FreeSessionLifecycle.swift](../../dejaview/Services/RemoteSession/FreeSessionLifecycle.swift)). That's enough to check on a Mac but too short to judge Glassy Stream's quality, and short trials tend to bring 1-star reviews. Consider a 7-day trial on the yearly plan, as Screens offers. The free tier could also be marketed as "check on your Mac for free."

## App features, by priority

### Tier 1: differentiators that support the headless story

1. **Virtual display sized to the device (Mac companion).** A headless Mac mini with no monitor attached captures at a poor resolution today, which is why people buy HDMI dummy plugs. The companion could create a virtual display matching the iPhone, iPad or Duo's exact aspect ratio, and resize it when the Duo folds or unfolds. No VNC client can do this. The catch: `CGVirtualDisplay` is a private API. That's acceptable for the Developer ID-distributed companion but may break between macOS versions.
2. **Remote access without a VPN.** This is Screens' biggest advantage (Screens Connect), and the [remote host connectivity plan](remote-host-connectivity-plan.md) already designs a relay. As an interim step:
   - The companion detects its Tailscale address and stores it with the pairing, so a saved Mac works over cellular automatically.
   - The app recognizes `100.x` addresses and MagicDNS names and offers a guided "Connect from anywhere" setup.
3. **Audio over Glassy Stream.** ScreenCaptureKit can capture audio. Screens' own listing says *"Sound transmission is not supported due to VNC protocol limitations,"* so this would be an easy point to advertise.
4. **Picture in Picture "watch mode."** The video view already uses `AVSampleBufferDisplayLayer` ([GlassyStreamVideoView.swift](../../dejaview/Views/Session/GlassyStreamVideoView.swift)), which is the layer type iOS Picture in Picture works with. A low-bitrate view-only floating window would let people watch a build or an AI agent while using other apps. Screens doesn't offer this.
5. **Automatic VNC fallback for reboots and the login window.** The companion only runs after someone logs in. When a headless Mac reboots, Glassy Desk should notice that and offer macOS Screen Sharing for the same machine. It should also guide headless setups through auto-login and wake settings.

### Tier 2: match Screens' feature list

- **Two-way clipboard.** Paste currently goes only from iPhone to Mac ([HostClipboardPasteService.swift](../../GlassyHost/Sources/GlassyHost/Services/HostClipboardPasteService.swift)). Add an explicit "Copy from Mac" action.
- **File transfer.** A "Send to Mac" share extension, plus drag and drop on iPad.
- **Face ID lock** for the app or for individual saved machines.
- **Live Activity** for the active session. It's in [feature ideas](feature-ideas.md) but isn't built.
- **Privacy screen / Curtain Mode.** Check whether this can be done for the Glassy Stream path. RoyalVNC probably doesn't support Apple's VNC version of it.
- **Apple Pencil:** no support yet.
- **Mouse capture** for a Magic Keyboard trackpad: there's hover support, but no capture of the pointer for relative movement.
- **Several sessions at once on iPad:** multiple windows are enabled in `Support/Info.plist`, but whether two sessions can run at the same time is unverified.
- **Dictation:** check that it works through the remote keyboard, then advertise it the way Screens does.

### Later

Native Mac and Vision Pro clients, and a "help a family member" mode like Screens Assist.

## If you only do five things

1. Rewrite the name, subtitle, keywords and description around the headless Mac mini and use cases. No code needed.
2. Redo the screenshots: 10 slots, less text, separate iPhone and Duo sets.
3. Add the review prompt.
4. Build the virtual display sized to the device.
5. Add Tailscale-assisted remote access, then the relay.

## Sources

- [Screens 5 App Store listing](https://apps.apple.com/us/app/screens-5-vnc-remote-desktop/id1663047912)
- [Screens site](https://www.edovia.com/en/screens/)
- [Glassy Desk App Store listing](https://apps.apple.com/us/app/glassy-desk/id6787767486)
- [MacStories: Screens 5 review](https://www.macstories.net/reviews/screens-5-an-updated-design-improved-user-experience-and-new-business-model/)
