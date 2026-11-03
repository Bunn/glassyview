# Apple-focused remote desktop competitors of Glassy Desk (as of 3 Nov 2026)

Evidence notes for the report writer:
- App Store pages were fetched on 3 Nov 2026. They show relative dates ("4 days ago") and often omit years. Absolute dates derived from them are marked as inferred.
- "Not listed" means the feature was absent from the product pages fetched. It does not prove the product lacks it.
- RealVNC blocked direct fetches (HTTP 403), and no current Chrome Remote Desktop App Store listing could be retrieved (404s). Both products have weaker evidence, flagged below.

## What does each product offer today?

### Takeaway
Jump Desktop 10 (GA Sept 2026) is the closest threat: it has audio, a virtual display and 120 fps on iPhone/iPad for a $14.99 one-time price. Screens 5 is the closest feature twin and shares Glassy Desk's no-audio gap, but it adds two-way rich clipboard, Live Activities and built-in remote access. Glassy Desk's clearest openings are 4K60 H.264 on a Mac from iPhone/iPad, which no Apple feature provides, against VNC-based Screens, and its much lower lifetime price against Screens.

### Compact gap matrix (evidence in the per-product findings below)

Legend: Y = confirmed; N = confirmed absent; ? = not confirmed either way; (Ent) = Jump Teams Enterprise only.

| Capability | Glassy Desk (from brief) | Screens 5 | Jump Desktop 10 | RealVNC Viewer | Apple High Performance | iPhone Mirroring | Windows App (iOS, remote PC) | Chrome Remote Desktop |
|---|---|---|---|---|---|---|---|---|
| Client on iPhone/iPad | Y | Y | Y | Y | N (Mac to Mac) | N (Mac controls iPhone) | Y | Y |
| Hosts | Mac (companion), VNC | Mac, Win, Linux, Pi | Mac, Win, Linux | Mac, Win, Linux | Mac | iPhone | Windows | Mac, Win, Linux |
| Protocol | Own H.264, VNC | RFB/VNC | Fluid/Fluid 2.0, RDP, VNC | VNC (RealVNC Connect) | Apple HP mode | Apple | RDP | Google proprietary (? not documented in sources) |
| Max stated quality on iOS | 4K60 | Adaptive/Full (no FPS stated) | Up to 120 fps; 20 Mbps cap free, 60 Mbps (Ent) | ? | 4K, 30/60 fps | ? | ? | ? |
| Audio from host | **N** | **N** (RFB) | **Y** (8-channel surround Ent) | ? | Y (stereo) | Y | Y | ? (2015 report: no) |
| Virtual/headless display | **N** | N (private background session only) | **Y** (1; up to 4 Ent) | ? | Y (1-2, up to 4K) | n/a | N (dynamic resolution N on iOS) | ? |
| Single-window streaming | **N** | Not listed | Not listed | ? | Not documented | n/a | RemoteApp via admin-published apps only | ? |
| Remote access without VPN | **N** (Tailscale routes only) | Y (Screens Connect, or built into Screens for Mac) | Y (auto setup, no router changes; relay/direct policy Ent) | Y (cloud sign-in) | Not documented; UDP 5900-5902 needed | Near Mac only | Via RD Gateway or admin services | Y (Google account) |
| Clipboard | One-way paste | **Two-way** (rich with Mac) | **Two-way** (rich text only) | ? | ? | ? | **Two-way** (text, images) | ? |
| File transfer | Y | Y (Mac; two-way, drag-drop, background) | Partial: RDP folder sharing; Fluid none as of Feb 2025 | ? | ? | ? | Y (folder redirection) | ? |
| Multi-session | ? (not in brief) | Y (multiple windows) | Y (iPad windows) | ? | 1 HP session per Mac | 1 Mac + 1 iPhone | Y (session switching) | ? |
| Session sharing/support | ? (not in brief) | Y (Screens Assist; Observe) | Y (Watch/guide/control; link) | ? | Observe mode | n/a | Not listed | Y (one-time code) |
| Curtain/privacy | Y | Y | Y (Privacy Mode) | ? | Y (blanks displays) | n/a | n/a | ? |
| Apple Pencil | Y | Y | Y (pressure/tilt/rotation Ent) | ? | n/a | n/a | Y (pen) | ? |
| Game controller | ? (not in brief) | Not listed | Y (+on-screen) | ? | n/a | n/a | Not listed | ? |
| External display | Y | Y (AirPlay, iOS 27) | Y | ? | n/a | n/a | Y (multi-monitor N) | ? |
| Widgets | Y | Y (Quick Connect) | Not listed | Not listed | n/a | n/a | Not listed | ? |
| Siri/Shortcuts | Y | Y (+Spotlight, URL schemes) | Not listed | Not listed | n/a | n/a | Spotlight; URI scheme (legacy) | ? |
| Live Activities | **N** | **Y** (file transfers) | Not listed | Not listed | n/a | n/a | Not listed | ? |
| Foldable (iPhone Duo) | Y | Y | Not found | Not found | n/a | n/a | Not found (iPhone 18 Pro support only) | ? |
| AI / agents | ? (not in brief) | Not listed | **Y** (CLI/MCP, Beta) | Not listed | n/a | n/a | AI-enabled Cloud PC indicator only | ? |

### Cited Findings

**Screens 5 (Edovia)**
- Connects from iPhone, iPad, Mac and Vision Pro to Mac, Windows, Linux and Raspberry Pi; Windows, Linux and Pi need a VNC server. Uses RFB; has SSH tunnelling and custom keys, Tailscale and Meshnet options, and Adaptive Quality — [Edovia product page](https://edovia.com/en/screens/)
- No audio from the remote computer, attributed to RFB — [Edovia product page](https://edovia.com/en/screens/); [App Store](https://apps.apple.com/us/app/screens-5-vnc-remote-desktop/id1663047912)
- Clipboard with a Mac carries text, rich text, images and URLs; with Windows, Linux or Pi it is plain text and URLs. File transfer works both ways with a remote Mac, with drag-and-drop — [Edovia product page](https://edovia.com/en/screens/)
- Background file transfers keep running after switching apps (iOS/iPadOS 26 API), with progress in a Live Activity — [Screens 5.7 post, 15 Sep 2025](https://blog.edovia.com/screens-57-now-available)
- Display and session controls: pick one remote display or all of them; Session Selection (shared session or private background session); Multiple Windows; Observe & Control; Curtain Mode; On-Disconnect Actions; Screens Assist (connect to a friend's or client's Mac through a free utility) — [Edovia product page](https://edovia.com/en/screens/)
- Curtain Mode may not activate on a background session because that desktop is virtual; no separate virtual display feature is described — [App Store](https://apps.apple.com/us/app/screens-5-vnc-remote-desktop/id1663047912)
- Input and automation: Touch and Trackpad modes, Apple Pencil, Dictation, Shortcuts Toolbar, Siri/Shortcuts/Spotlight, Quick Connect widgets, URL schemes, Face ID/Touch ID, and iPhone Duo dual-screen layout — [Edovia product page](https://edovia.com/en/screens/)
- Requires iOS/iPadOS 17.6 or later — [Edovia product page](https://edovia.com/en/screens/). Mac minimum conflicts: macOS 14.6 on the product page versus 14.0 on the [App Store](https://apps.apple.com/us/app/screens-5-vnc-remote-desktop/id1663047912)

**Jump Desktop 10 (Phase Five Systems)**
- iPhone/iPad: single virtual display matching device resolution and refresh rate, with Retina sharpness and rotation tracking; up to 120 fps on ProMotion; Codec menu (Fluid 2.0, Fluid, Hardware); audio streaming; RDP and VNC; multiple connections, with each computer in its own iPad window — [App Store](https://apps.apple.com/us/app/jump-desktop-rdp-vnc-fluid/id364876095)
- Also on iOS: physical mouse, Bluetooth keyboard macros, Apple Pencil, external display, game controllers and an on-screen controller, SSH tunneling, Touch ID, iCloud sync, RD Gateway, automatic remote-access setup with no router changes; drive redirection and printing apply to RDP — [App Store (localized US listing)](https://apps.apple.com/us/app/jump-desktop-rdp-vnc-fluid/id364876095?l=ko)
- Individuals tier: up to 480 fps, hardware encoding, 4:4:4, 1 virtual display, Privacy Mode, unlimited computers and connections, 20 Mbps video bandwidth. Enterprise adds up to 4 virtual displays, 10-bit color, 60 Mbps, USB devices, pen pressure/tilt/rotation, 8-channel surround, and relayed-only or direct connections — [Jump pricing](https://www.jumpdesktop.com/pricing-plans.html)
- Host claims: virtual displays at 120/144/240 Hz, up to six 4K monitors, USB pass-through, and support collaboration with watch, guide or control. AI agents via Jump CLI and MCP (Beta) can use up to 8 computers at once with Mission Control, free with any Jump account — [Jump site](https://www.jumpdesktop.com/)
- Fluid clipboard is two-way for text and formatted text, not images or files; on iPhone/iPad it syncs while the session window is active — [Jump docs](https://docs.jumpdesktop.com/viewer/session/clipboard/)
- File transfer: folder sharing works from iOS to Windows over RDP — [Jump support](https://support.jumpdesktop.com/hc/en-us/articles/115000714623-RDP-How-do-I-share-a-folder-over-a-RDP-connection). Fluid had no built-in transfer in late-2024 and Feb-2025 support replies (dated information; current state unconfirmed) — [community thread](https://support.jumpdesktop.com/hc/en-us/community/posts/32232469449229-Built-in-file-transfers-when)

**RealVNC Viewer / Connect**
- iOS app: connects to computers running RealVNC Connect; cloud connection with computers appearing after sign-in; described as end-to-end encrypted; touch as trackpad with gestures; backup and sync; key bar with Command/Windows keys; Bluetooth keyboard. Mice and trackpads added Mar 2023 — [App Store](https://apps.apple.com/us/app/realvnc-viewer-remote-desktop/id352019548)

**Apple High Performance Screen Sharing (Mac to Mac)**
- Stereo audio, HDR video reference mode, 4:4:4, 30 or 60 fps; both Macs must be Apple silicon on Sonoma 14 or later; 75 Mbps recommended per 4K display; wired recommended; UDP 5900-5902; virtual display maximum 4K (3840x2160 or 1920x1080 HiDPI); one HP session per Mac; authenticating as the logged-in user blanks the physical displays — [Apple Remote Desktop guide](https://support.apple.com/guide/remote-desktop/apdf8e09f5a9/mac)
- One or two virtual displays, each with its own resolution; Dynamic Resolution matches the local screen — [Six Colors, 8 Jun 2026](https://sixcolors.com/post/2026/06/high-performance-mode-allows-sharing-another-macs-display-as-if-your-own/)

**iPhone Mirroring (Mac controls iPhone)**
- Needs macOS 15 with Apple silicon or T2, iOS 18, the same Apple Account, and a locked iPhone near the Mac. No camera or microphone; audio plays through the Mac; not available in the EU — [Apple Support](https://support.apple.com/en-us/120421)
- macOS 27: resizable window (Apple's own apps for now), Control Center via Cmd+4, DRM video — [9to5Mac, 11 Oct 2026](https://9to5mac.com/2026/10/11/macos-27-brings-three-key-upgrades-to-iphone-mirroring/)

**Microsoft Windows App Mobile**
- Connects to Windows Pro/Enterprise/Server PCs, Windows 365, Azure Virtual Desktop, Dev Box and RDS; audio/video; folder, clipboard, mic and camera redirection; external monitor; Entra account switching; RD Gateway. Requires iOS 26 — [App Store](https://apps.apple.com/us/app/windows-app-mobile/id714464092)
- iOS/iPadOS matrix for remote PC connections: bidirectional clipboard (text and images), external display yes, multiple displays no, dynamic resolution no, USB no, printers no, speakers/mic/camera yes, pen yes, multi-touch yes, YubiKey-only smart card redirection in preview, URI schemes via the legacy RDP scheme — [Microsoft Learn, 11 Sep 2026](https://learn.microsoft.com/en-us/windows-app/compare-platforms-features)

**Chrome Remote Desktop**
- Hosts are Mac, Windows and Linux; viewers use Chrome or the mobile app; PIN access; "fully encrypted"; support sessions by one-time code with a 30-minute continuation prompt; needs internet — [Google Help](https://support.google.com/chrome/answer/1649523)
- A TechRadar review (date not established) found the mobile app missing Command, Control and Option keys — [TechRadar](https://www.techradar.com/reviews/chrome-remote-desktop-review&rut=505648db1b84c3ee7b8a75d627d42d433a0ed78d1ac13582966887a563776c20). A 2015 report said no audio on iOS (very dated) — [Techlicious](https://techlicious.com/blog/google-chrome-remote-desktop-app)

### Inferences
- Audio is Glassy Desk's most exposed gap against Jump and all of Apple's offerings, but it is not a gap against Screens, whose lack of audio stems from RFB. Because Glassy Desk owns its stream, audio could become a differentiator against Screens.
- Virtual display is table stakes among high-end products now that Jump offers it free on iOS and Apple has it Mac to Mac. Screens' background session is a weaker substitute.
- Two-way clipboard is a straightforward parity gap: Screens, Jump and Windows App all have it, and Screens exceeds Jump on Mac by carrying images.
- Glassy Desk's file transfer may be an advantage over Jump's Fluid path, if the 2025 statements still hold.
- Glassy Desk's Linux client has no counterpart among the iOS-focused rivals verified here, though Jump lists Linux (Alpha) among its platforms. Screens' pages describe only Apple clients.

### Gaps
- RealVNC plan feature gating (recording, SSO and similar) could not be read from RealVNC directly.
- RealVNC iOS: audio, file transfer, clipboard, multi-display and Pencil were not confirmable from sources I could reach.
- Chrome Remote Desktop iOS: no current source on clipboard, file transfer, audio or multi-monitor; live App Store listing not retrieved.
- Screens Connect transport (relay versus port mapping) was not confirmed; the blog teaser cut off before technical details.
- Jump's maximum resolution on iOS and whether the individual tier uses a relay were not stated. Jump's 480 fps and six-4K figures are general product claims, not iOS-specific.
- No source confirmed window streaming for Screens, Jump or RealVNC. Jump's pages describe "Separate display windows in the Windows app", which is a different feature.
- Glassy Desk's own status for multi-session, session sharing, game controller and AI was not in the brief, so those matrix cells need the writer's or owner's input.

## What is the current pricing and free tier, and what changed recently?

### Takeaway
Glassy Desk undercuts Screens on every plan: lifetime is $29.99 against $199.99. Jump's $14.99 one-time iOS price undercuts Glassy Desk's lifetime by half. Apple's features, Windows App, Chrome Remote Desktop and RealVNC's non-commercial Lite tier are free.

### Cited Findings
| Product | Price | Free tier / trial | Recent change |
|---|---|---|---|
| Glassy Desk (brief) | $1.99/mo, $19.99/yr, $29.99 lifetime | 80-second timed sessions | n/a |
| Screens 5 | $4.99/mo, $29.99/yr, $199.99 lifetime — [Edovia FAQ](https://help.edovia.com/en/screens-5/faq/s5-pricing); matches [App Store IAPs](https://apps.apple.com/us/app/screens-5-vnc-remote-desktop/id1663047912) | 7-day trial — [Edovia](https://edovia.com/en/screens/) | Launch price was $2.99/mo, $24.99/yr, $74 lifetime — [MacStories](https://www.macstories.net/reviews/screens-5-an-updated-design-improved-user-experience-and-new-business-model/). Older FAQ copies show $3.99/$24.99/$139.99 and a $119 lifetime — [mirror](https://help.edovia.com/en-GB/screens-5/faq/s5-pricing); [support subdomain](https://support.edovia.com/en/screens-5/faq/s5-pricing) |
| Jump Desktop | $14.99 one-time on iOS, no IAP, "not subscriptions!" — [App Store](https://apps.apple.com/us/app/jump-desktop-rdp-vnc-fluid/id364876095). Teams Pro $7.49 and Enterprise $14.99 per user/month; 20% off yearly — [Jump pricing](https://www.jumpdesktop.com/pricing-plans.html) | Free on Windows, Android and web; 14-day trial on Mac and Teams — [Jump pricing](https://www.jumpdesktop.com/pricing-plans.html) | In RC1 (4 Jul 2026), other USB device types came to require Teams Enterprise — [changelog](https://changelog.jumpdesktop.com/) |
| RealVNC | Lite: free, non-commercial, 1 user, 3 devices, one connection at a time — [RealVNC Lite](https://www.realvnc.com/en/connect/plan/lite/). Paid amounts unverified: search summaries gave Essentials at $8.25/mo and €7.25/mo, from pages I could not open, so no figure is confirmed — [RealVNC pricing (blocked)](https://www.realvnc.com/en/connect/pricing/) | Viewer free with trial or Lite — [RealVNC help](https://help.realvnc.com/hc/en-us/articles/35745908986653-Important-changes-to-RealVNC-Viewer-Information-and-FAQs) | Home plan retired (2024 app note) — [App Store](https://apps.apple.com/us/app/realvnc-viewer-remote-desktop/id352019548). Tracker reports Essentials $8.25 to $8.75 and Plus $16.50 to $18.25, undated — [Visualping](https://visualping.io/pages/vnc-connect-pricing-alerts-4893699) |
| Apple | Included with OS — [Apple guide](https://support.apple.com/guide/remote-desktop/apdf8e09f5a9/mac); [Apple Support](https://support.apple.com/en-us/120421) | Free | None found |
| Windows App | Free — [App Store](https://apps.apple.com/us/app/windows-app-mobile/id714464092) | Free; cloud services are licensed separately (not priced here) | None found |
| Chrome Remote Desktop | Free for support and personal use per Google's help flow, with no paid tier described — [Google Help](https://support.google.com/chrome/answer/1649523) | Free | None found |

### Inferences
- Screens' lifetime price rose from $74 at launch to $199.99 now. The FAQ copies suggest intermediate steps, but dates could not be established. Treat the trend as firm and the timing as unknown.
- Glassy Desk's monthly ($1.99 vs $4.99) and yearly ($19.99 vs $29.99) prices are lower than Screens', and its lifetime is about 15% of Screens'.
- Jump is cheaper as a one-off than Glassy Desk's lifetime, though Jump's Enterprise-only items (multiple virtual displays, 10-bit, 60 Mbps) mean power users pay $14.99 per month. Jump's free tier also caps video bandwidth at 20 Mbps; whether Glassy Desk's 4K60 stream exceeds that was not checked here.
- A timed free tier is stricter than the free options from Apple, Microsoft, Google and RealVNC Lite, and the 7- and 14-day rival trials give longer evaluation time.

### Gaps
- Live RealVNC pricing could not be read (HTTP 403). Plan tiers conflict between sources: Essentials/Plus/Premium/Enterprise versus Essentials/Enterprise.
- Exact dates of Screens price increases were not found.
- Whether Screens' subscription is required for remote access was not stated in the fetched posts.

## What shipped in 2025 and 2026, including iOS 26/27 and foldable support?

### Takeaway
Screens and Jump both moved fast through Sept-Nov 2026. Screens has explicit iPhone Duo and iOS 27 support. Jump has iOS 27 fixes but no Duo evidence. RealVNC ships minimally, and Windows App is iOS-26-only with an enterprise focus.

### Cited Findings

**Screens**
- 5.7 (15 Sep 2025): OS 26 support, background file transfers with Live Activity, iPad menu bar, Liquid Glass on Mac — [Edovia](https://blog.edovia.com/screens-57-now-available)
- 5.8 (12 Jan 2026): interactive toolbar customization. 5.8.6 (5 May 2026): Dictation (the App Store notes place it at 5.8.7, 2 Jun). 5.8.7 + Connect 5.3 (2 Jun 2026): Sign in with Apple and Google. 5.8.8 (22 Jun 2026): remote access built into Screens for Mac, macOS 14 or later, with no separate Connect install. 21 Jul 2026: Screens Connect reliability work. 17 Aug 2026: notice about CVE-2026-65400 in macOS Screen Sharing — [Edovia blog](https://blog.edovia.com/)
- 5.9 (14 Sep 2026): support for Apple's latest OSes, new quick-connect methods — [Edovia blog](https://blog.edovia.com/). App Store notes list Siri/Shortcuts/Spotlight actions, Quick Connect widget, custom grid ordering and AirPlay requiring iOS/iPadOS 27 — [App Store](https://apps.apple.com/us/app/screens-5-vnc-remote-desktop/id1663047912)
- 5.9.6/5.9.7 (late Oct 2026, inferred from "6 days ago"/"4 days ago"): fixes for iPad Home Screen quick actions and for the toolbar disappearing in portrait multitasking on iPhone Duo — [App Store](https://apps.apple.com/us/app/screens-5-vnc-remote-desktop/id1663047912)

**Jump Desktop**
- Jump 10 betas ran through mid-2026; virtual displays reached iOS in that cycle — [Beta 1](https://changelog.jumpdesktop.com/jump-desktop-10-beta-QXilW). RC1 (4 Jul 2026): game controller support and on-screen controller, redesigned Fluid display settings. RC7 (27 Aug): Single Virtual Display scaling. RC8 (31 Aug): external display and resize fixes. Jump 10 announcement dated 23 Sep 2026 — [changelog](https://changelog.jumpdesktop.com/)
- 10.17.1 (about 3 Nov 2026, inferred from "6h ago"): external display and keyboard fixes on iOS/iPadOS 27, toolbar fix on iOS 26+, per-computer audio/video sync for Fluid, on-device dictation, redesigned computer list with filters and tags, edge-to-edge host display — [App Store (localized US listing)](https://apps.apple.com/us/app/jump-desktop-rdp-vnc-fluid/id364876095?l=ko)

**RealVNC**
- 4.9.4 (9 Jun, year not shown): iOS/iPadOS 26 support. 4.9.5 (27 Oct, year not shown): stops trusting eight eMudhra intermediate CAs. No iOS 27 mention — [App Store](https://apps.apple.com/us/app/realvnc-viewer-remote-desktop/id352019548)

**Windows App**
- 2025: Spotlight (Apr), reconnect after network glitches (May), iPhone 17 support and W365 Cloud Apps (Dec), AVD screen capture protection and UDP option (Dec). 2026: Liquid Glass and iOS-26-only (11.3.0, 6 Apr, year inferred), WebAuthn passwordless (17 Sep), iPhone 18 Pro support (24 Sep), reliability update (27 Oct) — [App Store](https://apps.apple.com/us/app/windows-app-mobile/id714464092)
- Surface Arc Mouse and Surface Mouse pairing on iOS and Teams VDI 1.0 GA reported (undated in results) — [Eleven Forum](https://www.elevenforum.com/t/windows-app-updates-reliability-productivity-and-security-improvements.45707/latest)

**Apple**
- macOS Golden Gate list: Control Center and DRM in iPhone Mirroring, "Support for Mac mirroring in 5K resolution", "Expanded touch support in Sidecar" — [9to5Mac, 12 Jun 2026](https://9to5mac.com/2026/06/12/heres-everything-new-in-ios-27-and-more-per-apples-keynote-list/)

### Inferences
- Glassy Desk's iPhone Duo support is not unique: Screens has it. Against Jump, RealVNC, Microsoft and Google, it may be a real lead, but that rests on not finding evidence.
- Screens' 5.8.8 move closes its setup friction, which raises the bar for Glassy Desk's relay gap.

### Gaps
- A search summary said iPadOS 27 improved external display support and Sidecar, but I could not tie that to a specific page or find details, so treat it as unconfirmed.
- Apple-documented meaning of "Mac mirroring in 5K" and the specifics of "Expanded touch support in Sidecar" were not found. A remote control path from iPad to Mac over the internet was not found either.
- Chrome Remote Desktop has no verifiable 2025-2026 iOS changelog in the sources reached.
- Jump's Duo support could not be confirmed either way.

## What does each product advertise as its headline differentiators?

### Takeaway
Screens sells native-Apple polish and breadth of Apple integrations. Jump sells performance, creative and agent workflows, and no subscription. Microsoft sells enterprise reach, RealVNC sells cloud-managed security, and Google sells free browser-based simplicity.

### Cited Findings
- Screens: remote access to Mac, Windows, Linux and Pi with Screens Connect and Tailscale, Curtain Mode, Siri/Shortcuts/Spotlight, iOS and visionOS parity — [App Store](https://apps.apple.com/us/app/screens-5-vnc-remote-desktop/id1663047912)
- Jump: "Fast & secure remote desktop"; "not subscriptions!"; Jump 10 described as the biggest iPhone and iPad update in years — [App Store](https://apps.apple.com/us/app/jump-desktop-rdp-vnc-fluid/id364876095); site pitches 480 fps, hardware encoding on all Macs, USB pass-through, AI agents and Cloudless Fluid — [Jump site](https://www.jumpdesktop.com/)
- RealVNC: end-to-end encryption and cloud discovery — [App Store](https://apps.apple.com/us/app/realvnc-viewer-remote-desktop/id352019548)
- Windows App: a "gateway to securely connect to Windows including remote PCs" — [App Store](https://apps.apple.com/us/app/windows-app-mobile/id714464092)
- Chrome Remote Desktop: PIN-based access and one-time code support sessions — [Google Help](https://support.google.com/chrome/answer/1649523)

### Inferences
- No rival's fetched marketing leads on "4K60 from iPhone/iPad to a Mac" as a stated spec. Jump's marketing leads on higher FPS but does not state an iOS resolution figure, which leaves a usable messaging angle, subject to a head-to-head test.
- Glassy Desk's price and its combination of its own H.264 stream with standard VNC are its clearest messaging lines. Jump has this protocol breadth too, so the exclusive claim must lean on price against Screens and Mac-focused simplicity against Jump.

### Gaps
- Independent 2026 head-to-head reviews (MacStories, 9to5Mac) comparing Screens 5, Jump 10 and others on iPhone or iPad were not found. Performance comparisons in these notes rest on vendor claims.
- The RealVNC and Google marketing pages themselves could not be read in full.

## What do Apple's own features give users for free, and where do they stop?

### Takeaway
Apple gives Mac users a superb free Mac-to-Mac path (4K60, audio, virtual displays) and free Mac-to-iPhone mirroring, but no iPhone or iPad client for controlling a Mac was found in Apple's documentation. That is the core space Glassy Desk occupies.

### Cited Findings
- High Performance is documented only for Apple silicon Mac-to-Mac connections with 75 Mbps per 4K display and UDP 5900-5902 — [Apple guide](https://support.apple.com/guide/remote-desktop/apdf8e09f5a9/mac)
- Articles on the mode describe Mac-to-Mac use and do not cover iPad or iPhone; a commenter wished for an iPad Screen Sharing app — [9to5Mac, 5 Feb 2026](https://9to5mac.com/2026/02/05/how-to-use-macos-high-performance-screen-sharing-for-lower-latency-and-better-color-video/); [Six Colors](https://sixcolors.com/post/2026/06/high-performance-mode-allows-sharing-another-macs-display-as-if-your-own/)
- iPhone Mirroring flows only from Mac to iPhone, requires a locked iPhone nearby, excludes camera, mic and Face ID, and is unavailable in the EU — [Apple Support](https://support.apple.com/en-us/120421)
- Resizing in iPhone Mirroring is currently limited to Apple's native apps — [9to5Mac](https://9to5mac.com/2026/10/11/macos-27-brings-three-key-upgrades-to-iphone-mirroring/)
- Vision Pro: Mac Virtual Display works with macOS 14 or later; ultrawide modes need Apple silicon, macOS 15.2 and visionOS 2.2 — [Apple Support](https://support.apple.com/en-vn/119942)
- Mac User Guide for macOS 27 lists "Use your iPad as a second display" and "Use one keyboard and mouse to control Mac and iPad" — [Apple Mac User Guide](https://support.apple.com/en-ph/guide/mac-help/mh43558/mac)
- A macOS Screen Sharing vulnerability, CVE-2026-65400, could let a network attacker authenticate, per Edovia's Aug 2026 notice (excerpt only; Apple's advisory not read) — [Edovia blog](https://blog.edovia.com/)

### Inferences
- Sidecar and Universal Control extend a Mac onto an iPad but do not let an iPad remotely operate a Mac from elsewhere, so they do not replace Glassy Desk. This is drawn from feature names in Apple's guide, not an explicit Apple statement of limits.
- Apple's Mac-to-Mac High Performance sets user expectations for audio and virtual displays, so Mac users who try it may find Glassy Desk's missing features more noticeable.
- A viable Apple threat would be iPad or iPhone support for High Performance Screen Sharing. No such feature was found through iOS/iPadOS 27.

### Gaps
- No Apple primary source explicitly says "no iPad client for Screen Sharing"; this is an absence in docs and coverage. I found no iPadOS 27 or iOS 27 Continuity feature that provides remote Mac control, and could not read Apple's full release notes.
- Whether High Performance mode works over the internet or VPN is not documented in sources read, beyond the UDP port requirement.
- No Apple Intelligence or AI remote control feature was found in the 9to5Mac keynote list, but that list was checked only by keyword extraction.
