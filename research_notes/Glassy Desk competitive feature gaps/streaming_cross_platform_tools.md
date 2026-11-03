# Low-latency streaming and cross-platform remote access tools: competitors and sources of ideas for Glassy Desk

State as of 3 November 2026. Items are dated where the source gives a date. Search and fetch results were read through a summarizer, so treat exact wording as paraphrase. Several official pages returned 403 or no usable content: AnyDesk pricing, Parsec support articles, and TeamViewer plan tables. Those points rest on search snippets or third parties and are flagged. Anything with no source is in Gaps. Remarks about Glassy Desk's own capabilities come from the assignment brief, not from checking the code.

## Which codecs, frame rates, latency numbers, HDR, audio, microphone passthrough, and gamepad support does each offer on iOS and macOS?

### Takeaway
On a Mac-host-to-iOS-client path, the closest and newest rival is the open source Glass, which claims about 20 ms plus audio, microphone, Pencil pressure and P3 color. Parsec has no official iOS client, Sunshine on macOS is still "experimental" with no gamepads, and published latency figures are nearly all vendor claims.

### Cited Findings

**Parsec**
- Official hosts are Windows 10+ and macOS 10.15+. Official clients are Windows, Web (Chrome), macOS 10.15+ (Metal only), Android and Linux. No iOS or iPadOS client is listed — [Parsec downloads](https://parsec.app/downloads)
- iOS access exists only through the third-party open source OpenParsec, built on the Parsec SDK with mouse, keyboard and touch support. Its current status is unconfirmed — [OpenParsec](https://github.com/hugeBlack/OpenParsec)
- Build 150-105b (5 Oct 2026) fixed a client decode failure with macOS hosts when 10-bit color is on. Build 150-105c (8 Oct 2026) fixed an H.264 quality problem on certain decoders — [Parsec changelog](https://parsec.app/changelog)
- 4:4:4 color, up to 3 monitors, privacy mode, and Wacom pressure and tilt are paid features, from the Individuals (Warp) plan up — [Parsec pricing](https://parsec.app/pricing)
- The 150-105 release raised the maximum to 5 screens, including virtual monitors. Host and client must be on the same release. This comes from a search summary of the changelog; the pricing page still says 3 — [Parsec changelog](https://parsec.app/changelog)
- Gamepad input passes from client to host through Parsec's virtual USB driver. The docs are written for desktop clients — [Parsec gamepad setup](https://support.parsec.app/hc/en-us/articles/32381705301908-Setup-Gamepad)

**Sunshine + Moonlight, and Apollo**
- Sunshine on macOS is labeled "experimental". Gamepads do not work. Moonlight does not forward Command keys, so Right Option maps to Command. Native system audio capture needs macOS 14+; otherwise BlackHole or Soundflower. HDR is documented only for Windows (official) and Linux (experimental) — [Sunshine docs](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2getting__started.html)
- Sunshine uses VideoToolbox on macOS, according to a search summary of a GPU-encoding table, probably from this third-party copy of its docs — [Mintlify Sunshine docs](https://www.mintlify.com/LizardByte/Sunshine/introduction)
- Minimum macOS and latest version conflict among secondary sources: macOS 14.2+, 14+ or 12, and releases dated May, June and an August 2026 pre-release. Current stable is unconfirmed — [Tech Insider](https://tech-insider.org/sunshine-moonlight-setup-2026/); [Fossies README](https://fossies.org/linux/Sunshine/README.md)
- Moonlight iOS is GPL-3.0, covers iOS, iPadOS and tvOS, and has 1.7k stars. The README does not list codecs, HDR or gamepad behavior — [moonlight-ios](https://github.com/moonlight-stream/moonlight-ios)
- A Moonlight visionOS fork reports AV1 and AV1 HDR working on M5 devices. This is not iOS — [moonlight-ios-vision](https://github.com/RikuKunMS2/moonlight-ios-vision)
- A third-party media-app forum says AV1 hardware decode needs A17+ or M3+ and that those chips also handle HDR. This is not a Moonlight test — [Firecore forum](https://community.firecore.com/t/av1-hardware-decoding-m3-a17-pro/44912)
- Sunshine maintainers said 4:4:4 needs client changes as well and that AV1 4:4:4 hardware encoding was absent at the time. The thread is undated, so this may be stale — [LizardByte discussion 220](https://github.com/orgs/LizardByte/discussions/220)
- Apollo is a Sunshine fork listing Windows 10+, macOS 12+ and Linux. Its virtual display with HDR is Windows-only, with Linux planned — [Apollo](https://github.com/ClassicOldSong/Apollo)

**RustDesk**
- In 2025 discussion #13071, a Mac host lacked AV1 hardware encoding while the iOS controller kept selecting AV1. This is a bug report, and its current state is unknown — [RustDesk discussion 13071](https://github.com/rustdesk/rustdesk/discussions/13071)
- 1.5.0 changed QoS handling of delay, congestion and FPS targets (blog post dated 14 Oct 2026) — [RustDesk blog](https://rustdesk.com/blog/)
- A 2026 roundup gives about 30-50 ms latency for RustDesk. This is a low-quality, unmeasured figure — [Vecosys roundup](https://www.vecosys.com/best-remote-desktop-apps-2026/); [Remogrid roundup](https://www.remogrid.com/blog/remote-work/best-free-remote-desktop-software) (the summary did not say which of the two)

**Splashtop**
- The Performance plan lists 4:4:4, a 240 FPS capability, high-fidelity audio, stylus and Wacom bridge, and USB passthrough — [Splashtop pricing](https://www.splashtop.com/pricing)
- Turbo FPS is best-effort, depends on hardware and content, requires Mac app and Streamer 3.7.0.0+, and excludes some Mac chips — [Splashtop Turbo FPS](https://support-splashtopbusiness.splashtop.com/hc/en-us/articles/21548143528219-Turbo-FPS-option-Up-to-240-FPS)
- A February 2026 press release introduced an "AI-optimized codec" and claims Splashtop alone consistently sustained 4K60 in its own comparison. This is a vendor claim — [Splashtop press](https://www.splashtop.com/press/splashtop-introduces-ai-optimized-codec-to-power-smoother-workflows)
- Mic passthrough supports Mac Streamer 3.4.8.4+ but only in unattended sessions. With concurrent sessions, the first one to redirect owns the mic — [Splashtop mic passthrough](https://support-splashtopbusiness.splashtop.com/hc/en-us/articles/360055835272-Microphone-Passthrough)
- Apple Pencil pressure and tilt from iPad work only when connecting to a Windows 10+ streamer. I found no Mac-host support — [Splashtop stylus](https://support-splashtopbusiness.splashtop.com/hc/en-us/articles/360055551332-Remote-Stylus-Apple-Pencil-Windows-iOS-Android)

**HP Anyware**
- PCoIP Ultra is on by default and supported on Apple Silicon from macOS agent 22.09. The macOS Graphics Agent supports up to 4 displays and a maximum of 4K UHD — [HP Anyware PCoIP Ultra](https://anyware.hp.com/components/software-client-for-macos/25.06/documentation/administrators-guide/pcoip-ultra); [HP macOS agent docs](https://www.teradici.com/web-help/pcoip_agent/graphics_agent/macos/current)

**Glass (new, MIT-licensed; note the near-collision in name: glassdesk.dev)**
- The Mac captures with ScreenCaptureKit, encodes hardware H.264 with VideoToolbox, and sends over WebTransport datagrams with no jitter buffer. The browser decodes with WebCodecs. A per-viewer mode uses HEVC 4:2:2 for motion and lossless 4:4:4 when the screen is still. Claimed latency is about 20 ms, with a live meter typically at 15-30 ms on a home network or tailnet — [Glass README](https://github.com/Ntarasiuk/glass)
- The site claims Display P3, up to 120 fps on fast screens, adaptive bitrate, system audio, microphone through a bundled Glass Microphone driver on Mac, and Apple Pencil pressure and tilt on Mac. All are vendor claims with no independent measurement — [Glass site](https://glassdesk.dev/)
- Game controllers conflict: the site says Linux, while the README mentions controllers generally and a ViGEmBus requirement for Windows — [Glass site](https://glassdesk.dev/); [Glass README](https://github.com/Ntarasiuk/glass)
- The viewer needs Safari 26.4+, Chrome, Edge or Firefox, and no app is installed — [Glass README](https://github.com/Ntarasiuk/glass)

### Inferences
- Glassy Desk's H.264 up to 4K60 is at parity on the codec headline with Glass's base mode, but it lacks audio, microphone, and possibly the adaptive motion/still codec trick. Audio is the most visible gap: every serious rival here offers it, and Sunshine, Glass and Splashtop document how they do it on macOS.
- Glass's HEVC 4:2:2 in motion and 4:4:4 when still is a directly adoptable idea for text sharpness, which suits productivity use on iPad. VideoToolbox availability for each profile needs testing on target Macs.
- Native iOS plus Mac host is a real opening: Parsec has no official iOS client, Sunshine on macOS is experimental and lacks gamepads, and Splashtop's Pencil support excludes Mac hosts. Glass is browser-based, so a native client can still differ on keyboard capture, background behavior and App Store distribution.
- Pencil pressure and tilt to a Mac host is demonstrably possible (Glass) and absent from Splashtop's Mac path, making it a differentiator for creative users.

### Gaps
- Moonlight iOS's current codec, HDR, microphone and gamepad behavior: the README is silent and no official wiki page was fetched. It is commonly understood to support HEVC and gamepads, but I did not confirm this.
- Parsec's macOS-host audio and mic behavior: the support article returned 403.
- AnyDesk, TeamViewer and NoMachine iOS and macOS codec and audio details: no primary source found. NoMachine H.265 on Apple clients is unconfirmed.
- HP Anyware's iOS client: only a general statement that PCoIP clients can run on iOS, with no version details.
- I found no independent, measured glass-to-glass latency comparison on Mac-to-iOS for any tool.

## How does each handle virtual displays and resolution matching to the client device?

### Takeaway
Apollo sets the benchmark (per-client virtual display matching resolution and framerate) but only on Windows. On Mac, tools either make limited virtual displays (Parsec), lean on third-party apps (BetterDisplay, SimpleDisplay), or reshape the desktop (Glass, Jump Desktop per anecdote). A native "exact client-resolution display" on Mac is a contestable feature.

### Cited Findings
- Apollo's built-in virtual display (SudoVDA) has HDR support and automatically matches client resolution and framerate. Each client has a fixed identity, so Windows remembers its display settings. It is Windows-only for now — [Apollo](https://github.com/ClassicOldSong/Apollo)
- The Artemis client controls virtual display options from the client side, but runs only on Android — [Apollo](https://github.com/ClassicOldSong/Apollo)
- Latest Apollo stable is v0.4.6 (13 Jul, year not shown), with v0.4.7-alpha.1 (12 Aug). Notes refer to Windows features such as an isolated virtual display option — [Apollo releases](https://github.com/ClassicOldSong/Apollo/releases)
- Parsec Virtual Displays (Beta) add displays during owner connections. Privacy Mode can turn off physical displays while virtual ones are on, and the host auto-locks after the last guest leaves. Full control requires Teams or Warp; free users get only a single-display fallback when none is detected — [Parsec host settings](https://support.parsec.app/hc/en-us/articles/360002165172) (via search snippet; direct fetch not attempted because other support pages returned 403)
- A user forum thread (date unconfirmed, anecdotal) says Parsec Mac virtual displays offered only 16:9 or 16:10, suggests BetterDisplay or Virtual Display Pro, and prefers Jump Desktop because it auto-creates a virtual display at client resolution — [Logik forum](https://forum.logik.tv/t/parsec-on-mac-matching-client-resolution/10531)
- Glass claims viewers can match native text size, show all displays side by side, or use an iPad or laptop as an extra display "like Sidecar", with a fit-this-device resolution option. The mechanism is not explained — [Glass README](https://github.com/Ntarasiuk/glass); [Glass site](https://glassdesk.dev/)
- Remote Display, a RustDesk 1.4.9 fork with 9 stars, shipped its own macOS virtual display backend up to 1.0.8, then removed it. It now defers to SimpleDisplay or macOS and says it does not create virtual monitors — [Remote Display](https://github.com/SamuelRioTz/remotedisplay)
- A search snippet described that same fork's 1.0.1 release as having virtual monitors, which fits the earlier backend and is superseded by the current README — [Remote Display 1.0.1](https://github.com/SamuelRioTz/remotedisplay/releases/tag/v1.0.1)
- HP Anyware's macOS agent caps at four displays and 4K UHD — [HP macOS agent docs](https://www.teradici.com/web-help/pcoip_agent/graphics_agent/macos/current)

### Inferences
- A small project shipping and then abandoning its own macOS virtual display backend signals real maintenance cost. Check its docs folder for test notes before building.
- Glassy Desk's display-only capture model already fits a virtual display approach. The feature to aim for is a display at exact client points and scale (including iPad and foldable aspect ratios), remembered per client as Apollo does, with physical displays optionally blanked as in Parsec's privacy mode.

### Gaps
- Which macOS API each tool uses for virtual displays (for example, private CGVirtualDisplay): not documented in sources found.
- RustDesk, AnyDesk, TeamViewer, Splashtop and NoMachine virtual display behavior on macOS: no confirmation. The Splashtop [headless blog post](https://www.splashtop.com/blog/future-of-headless-computing) appeared in results but was not read.
- Current behavior of Parsec's Mac virtual displays after the 150-105 release is unconfirmed; the aspect-ratio complaint may be dated.

## How does each handle connectivity without a VPN (relay, NAT traversal, self-hosting), and what does it cost?

### Takeaway
Paid tools bundle hosted connectivity, while open source tools offer self-hosting. RustDesk and Glass have just moved to WebRTC-based direct paths, which is a cheap template for Glassy Desk to add a no-VPN path without running heavy relay infrastructure.

### Cited Findings
- RustDesk 1.5.0 (blog dated 14 Oct 2026) adds WebRTC connection paths and direct access from the web client — [RustDesk blog](https://rustdesk.com/blog/)
- A German outlet says 1.5.0 was declared final by 2 Oct 2026, highlighting other changes and not mentioning WebRTC — [Deskmodder](https://www.deskmodder.de/blog/2026/10/02/rustdesk-1-5-0-ist-erschienen/). The 1.5.1 changelog includes a fix for reporting one error when both "WebRTC race legs" fail — [linuxserver Docker release](https://github.com/linuxserver/docker-rustdesk/releases/tag/1.5.1-ls132)
- A fork's wiki says the setting is opt-in on the connecting device, needs 1.5.0+ on both sides, and that stock rustdesk-server does not pass WebRTC offers. Verify before relying on this — [CortenDesk wiki](https://github.com/marcpope/cortendesk/wiki/WebRTC-Connections)
- RustDesk self-hosting: the open source tier is $0. Pro Individual is $11.88/mo billed annually (1 user, 20 devices, unlimited concurrency, distributed relays). Basic is $23.88/mo (10 users, 100 devices, OIDC, LDAP, custom client generator). Annual only — [RustDesk pricing](https://rustdesk.com/pricing/)
- Glass: on a tailnet, it uses TLS 1.3 over QUIC gated by Tailscale identity. `glass link --anywhere` uses end-to-end encrypted WebRTC with no open ports and no Tailscale on the viewer. A self-hostable relay is listed — [Glass README](https://github.com/Ntarasiuk/glass); [Glass site](https://glassdesk.dev/)
- Parsec's "high-performance relay server" is Enterprise only, at $45/user/mo billed annually — [Parsec pricing](https://parsec.app/pricing)
- NoMachine: automatic UPnP/NAT-PMP port mapping has been off by default since v8 and can be enabled in the UI or `server.cfg` — [NoMachine KB](https://kb.nomachine.com/AR04S01122)
- Remote Display has no relay and needs a LAN or VPN such as Tailscale — [Remote Display](https://github.com/SamuelRioTz/remotedisplay)

### Inferences
- Glassy Desk's "no relay" stance is now weak against both a free MIT rival and RustDesk. A first step could be WebRTC or QUIC with a minimal signaling service and optional self-hosted TURN, keeping recurring costs compatible with $1.99/mo. A hosted media relay is the piece that could break those margins.
- Tailscale-native positioning has low cost: Glass demonstrates using tailnet identity as the access gate, and could be copied as detection and pairing for a Mac on the same tailnet.

### Gaps
- Parsec's default NAT traversal details and its non-Enterprise relay fallback: not confirmed.
- AnyDesk, TeamViewer and Splashtop backbone routing, and whether they offer self-hosting: only a Splashtop on-prem docs site was seen in passing, and pricing was not obtained.
- No sourced figures on what percentage of sessions need a relay.

## Which have collaboration features, such as session sharing, multi-user cursors, or guest links?

### Takeaway
Time-limited guest links and on-screen drawing are widely available, and Glass offers granular one-time links for free. I found no strong confirmation of true multi-user cursors on macOS in these sources, so this remains an open idea rather than a proven pattern.

### Cited Findings
- Parsec Guest Access is on Teams and Enterprise, costs $25 per invitation, and grants temporary access for up to five days — [Parsec pricing](https://parsec.app/pricing)
- Glass one-time links can be view-only, block files or clipboard, be time-limited, require "ask first" approval, or need a passkey. It also has a no-install quick-support code, chat, on-screen drawing and a privacy screen — [Glass site](https://glassdesk.dev/)
- Splashtop Pro allows up to 3 users into one computer plus chat and session recording — [Splashtop pricing](https://www.splashtop.com/pricing). A feature matrix describes two team members remoting into one machine from separate accounts — [Splashtop feature matrix](https://www.splashtop.com/api/assets/21lBvAeHqXKduMeNqRk48a/Splashtop-Remote-Access-Feature-Matrix.pdf)
- NoMachine Enterprise guest desktop sharing lets users share with co-workers without giving the system password or unattended access. Multiple users can connect concurrently; Mac and iOS applicability was not stated — [NoMachine product page](https://www.nomachine.com/product&p=NoMachine%20for%20Mac)
- Apollo gives per-client permissions: the first paired client gets full permissions, and later ones get only View Streams and List Apps until granted Launch Apps, Mouse Input or Keyboard Input — [Apollo](https://github.com/ClassicOldSong/Apollo)
- TeamViewer licensing requires only the expert to hold a license, and session participants do not — [TeamViewer pricing](https://www.teamviewer.com/en-us/pricing/)

### Inferences
- A signed one-time guest link with Glass-style scopes plus Apollo-style per-client permissions would fit Glassy Desk well, and it undercuts Parsec's $25 per invitation.
- View-only links are the easiest first step since they need no input authorization.

### Gaps
- Multi-user cursors: no source confirmed separate labeled cursors on macOS for any tool. Parsec multi-user input on macOS hosts was not verified.
- AnyDesk and TeamViewer iPad invite-link flows: the targeted search returned nothing useful.

## Which have unattended access, remote reboot, or pre-login access, and how do they do it on macOS?

### Takeaway
On macOS, FileVault is the hard wall: third-party services do not run until the disk is unlocked. macOS Tahoe's SSH pre-boot unlock now gives a supported path that a host app could guide users through, which most competitors do not appear to surface.

### Cited Findings
- From macOS Tahoe 26, a Mac can be unlocked by SSH at pre-boot with Remote Login enabled beforehand, then full boot completes and Screen Sharing connects. Coverage says Apple Silicon only — [Jeff Geerling](https://www.jeffgeerling.com/blog/2025/you-can-finally-manage-macs-filevault-remotely-tahoe/); [Michael Tsai](https://mjtsai.com/blog/2025/09/22/tahoe-filevault-icloud-keychain-and-ssh/); [Mac Mini Vault FAQ](https://www.macminivault.com/faq/can-i-enable-filevault-on-my-remote-mac/?seq_no=2)
- Sources report Wi-Fi failing and wired Ethernet working for this unlock. Unplanned reboots still leave the machine waiting for someone to act — [Tsai roundup](https://mjtsai.com/blog/2025/09/22/tahoe-filevault-icloud-keychain-and-ssh/); [Mac Mini Vault FAQ](https://www.macminivault.com/faq/how-to-avoid-common-mistakes-with-a-hosted-mac/)
- `sudo fdesetup authrestart` handles planned reboots but needs the user's password or recovery key — [TeamViewer community](https://community.teamviewer.com/English/discussion/comment/87911); [Twocanoes KB](https://twocanoes.com/knowledge-base/unlock-filevault-automatically/)
- TeamViewer: forum answers say the FileVault screen precedes the real login screen, so no apps run or network exists. Users also report post-update Setup Assistant screens blocking access until someone clicks through. These are community reports of mixed age — [TeamViewer community](https://community.teamviewer.com/English/discussion/133734/teamviewer-15-installed-on-mac-cant-connect-after-reboot); [TeamViewer setup assistant thread](https://community.teamviewer.com/English/discussion/29929/apple-setup-assistant-blocks-remote-connection)
- TeamViewer has a remote reboot action, per an older guide and press release (dates unconfirmed) — [TechRepublic](https://www.techrepublic.com/fr/article/how-to-remotely-control-a-mac-with-teamviewer/)
- Parsec login-screen access on macOS requires a separate custom installer with additional requirements, and permission setup cannot be automated — [Parsec Install on macOS](https://support.parsec.app/hc/en-us/articles/4423549357837-Install-Parsec-app-on-macOS) (via search snippet)
- Glass runs as the user, not root, and needs Screen Recording and Accessibility. It claims to wake a sleeping machine with Wake-on-LAN and unlock it from the lock screen — [Glass README](https://github.com/Ntarasiuk/glass); [Glass site](https://glassdesk.dev/)
- Splashtop Solo includes unattended access from $6/mo; scheduled access is Enterprise — [Splashtop pricing](https://www.splashtop.com/pricing)
- RustDesk's August 2026 Wayland preview adds unattended and login-screen access after reboot on x86_64 Debian and Ubuntu. This is Linux only, not macOS — [RustDesk blog](https://rustdesk.com/blog/)

### Inferences
- Glassy Desk could offer a "survive a reboot" flow: pre-check FileVault and Remote Login state from the companion, explain Ethernet needs, offer authrestart for planned reboots, and let the iOS client perform or guide the SSH unlock. Check App Review implications of an embedded SSH client, and test on real hardware.
- Wake-on-LAN and lock-screen unlock from Glass are direct feature candidates. How Glass unlocks the lock screen was not documented in what I read, so security review is needed.

### Gaps
- Pre-login specifics on macOS for AnyDesk, Splashtop and NoMachine: no source found. RustDesk macOS pre-login: not confirmed.
- Whether any competitor integrates Tahoe's SSH unlock in its UI: none found, but this is absence of evidence only.
- Whether macOS 27 changed this flow: not checked.

## What pricing and licensing changes have provoked backlash?

### Takeaway
TeamViewer's commercial-use flagging remains the classic grievance and AnyDesk's 2024 breach the classic trust failure. Current list prices sit far above Glassy Desk's $1.99/mo, but free open source tools now bracket it from below. I found no new major 2026 backlash event.

### Cited Findings

**TeamViewer**
- Commercial use is defined as any use directly or indirectly paid for, and TeamViewer may suspect or detect it on accounts and IDs — [TeamViewer KB](https://www.teamviewer.com/en-cis/global/support/knowledge-base/teamviewer-classic/licensing/personal-use/commercial-use-suspected)
- Users report false positives for family support, blocking despite submitted proof, and long sessions triggering flags. These are anecdotal and of varied age — [TeamViewer community](https://community.teamviewer.com/English/discussion/comment/42292); [Technibble](https://www.technibble.com/forums/threads/teamviewer-stops-commercial-use-checks-in-coronavirus-affected-regions.84541) (the summary did not attribute each quote precisely)
- Pricing: from $24.90/mo per Softabase (verified March 2026), $24.9-$229.9/mo per CostBench (August 2026). Official tables were not readable — [Softabase](https://softabase.com/software/remote-desktop/teamviewer); [CostBench](https://www.costbench.com/software/remote-desktop/teamviewer/hidden-costs/)
- Plans are annual and auto-renew unless canceled at least 28 days before term end. Nonprofit and education get 30% off — [TeamViewer pricing](https://www.teamviewer.com/en-us/pricing/)

**AnyDesk**
- February 2024: attackers reached production systems. Source code and signing certificates were exposed. AnyDesk revoked certificates and web-portal passwords and said it had no evidence end-user devices were affected — [SecurityWeek](https://www.securityweek.com/anydesk-revokes-passwords-certificates-in-response-to-hack/amp/); [Dark Reading](https://www.darkreading.com/endpoint-security/anydesk-compromised-passwords-revoked)
- Resecurity reported 18,000+ customer credentials for sale, apparently unrelated to the breach — [Bitdefender](https://www.bitdefender.com/en-us/blog/hotforsecurity/anydesk-revokes-passwords-after-hacker-attack-threat-actors-advertise-stolen-data)
- Prices per an October 2026 capture: Solo $28.90, Standard $49.90, Advanced $111.90/mo billed annually, connection add-on $44.90 — [PricingSaaS](https://pricingsaas.com/companies/anydesk). Device caps of 100, 500 and 1,000, with no month-to-month plan, come from a competitor and a review site — [Splashtop blog](https://www.splashtop.com/blog/anydesk-price-increase); [SpotSaaS](https://www.spotsaas.com/blog/anydesk-pricing). SpotSaaS conflicts on list prices ($37.90, $63.90, $138.90)
- A 20% promotional discount was removed on 18 May 2026 — [PricingSaaS](https://pricingsaas.com/companies/anydesk/diffs/2026W21) (week link inferred from search results; company page holds history)

**Positioning and price table**
- Parsec (page footer says 2026, no effective dates): Free personal; Individuals $8.33/user/mo billed annually; Teams $30; Enterprise $45. The page also shows unlabeled $9.99 and $35 figures. Free and Individuals are non-commercial only — [Parsec pricing](https://parsec.app/pricing)
- Splashtop: Solo $6/mo ($72/yr); Pro $8.25/user/mo ($99/yr); Performance $13/user/mo ($149/yr as shown, which does not equal 12 x $13) — [Splashtop pricing](https://www.splashtop.com/pricing)
- RustDesk: see connectivity section. Positioned as open source, self-hosted — [RustDesk pricing](https://rustdesk.com/pricing/)
- NoMachine: free personal tier. Enterprise Desktop about $45/computer/yr or $244.50 for a 10 pack. Terminal Server figures conflict ($229 to $1,495 a year). Aggregators only, and the search summary did not tie each figure to a specific one — [SaaSRat](https://saasrat.com/products/nomachine); [Techjockey](https://techjockey.com/detail/nomachine)
- HP Anyware: an undated reseller shows $397.12 for a one-year Graphics Agent, one host, unlimited clients one at a time — [EAR store](https://store.ear.net/products/hpe-u12ypsl)
- Shadow (cloud PC, adjacent rather than direct): Neo $37.99 and Power $54.99/mo appear in two secondary sources, but lower tiers conflict — [Tech Insider](https://tech-insider.org/ie/xbox-cloud-gaming-vs-boosteroid-vs-shadow-pc-2026/); [Subger](https://subger.com/en/service/shadow-pc)
- Glass and Moonlight/Sunshine/Apollo: free, open source (MIT for Glass, GPL-3.0 for Apollo and Moonlight iOS) — [Glass site](https://glassdesk.dev/); [Apollo](https://github.com/ClassicOldSong/Apollo); [moonlight-ios](https://github.com/moonlight-stream/moonlight-ios)

### Inferences
- Glassy Desk's clear personal/commercial stance and monthly option are marketable against annual-only rivals (RustDesk, AnyDesk, Splashtop's displayed billing) and against flag-based enforcement. Avoid any automated commercial-use detection.
- A remote-access app is a supply chain target. AnyDesk's case supports publishing a security page and signing or key-rotation plan.
- The $29.99 lifetime offer is unusual among those priced here (none listed one), though it could carry relay cost risk if a hosted relay is later added.

### Gaps
- No 2025-2026 documented backlash wave for AnyDesk's free plan or new TeamViewer events was found. Official current AnyDesk and TeamViewer price tables were not accessible.
- Parsec's unlabeled figures are presumably monthly-billed prices, but this is not confirmed.
- The Shadow iOS price and any platform differences were not confirmed.

## What features are unique or novel enough to inspire a new feature on Apple devices?

### Takeaway
The most inspiring items are Glass's agent-control MCP server, hybrid codec, and scoped links, plus Apollo's per-client display identity and Parsec's privacy mode. Adding Tahoe-era FileVault help and native Pencil input would give a strong Apple-focused story.

### Cited Findings
- `glass mcp` lets AI agents use your computers while a person can watch, pause, stop, or approve actions — [Glass site](https://glassdesk.dev/)
- Glass adds two-way rich text and image clipboard, two-way file transfer, an owner-only file browser, and media controls for what the computer plays surfaced in the browser and lock screen — [Glass site](https://glassdesk.dev/)
- Each Glass frame carries a checksum, corrupted frames are never decoded, and lost packets do not delay newer frames — [Glass README](https://github.com/Ntarasiuk/glass)
- RustDesk's 1.4.x and 1.5 line has mobile terminal additions (float control bar in 1.4.5, Jan 2026; mobile Ctrl/Alt in 1.5.0) and monitor-switch buttons plus multi-monitor privacy mode in 1.4.8 (June 2026, low-quality source) — [Scout history](https://scout.appaloosa.io/en/apps/ios/com.carriez.flutterHbb/history); [Deskmodder](https://www.deskmodder.de/blog/2026/10/02/rustdesk-1-5-0-ist-erschienen/); [abit.ee](https://abit.ee/en/soft/rustdesk-remote-desktop-teamviewer-open-source-windows-arm64-self-hosted-rust-en)
- RustDesk's custom client generator (Basic and up) produces branded clients — [RustDesk pricing](https://rustdesk.com/pricing/)
- Splashtop's stylus bridge, USB passthrough and Turbo FPS mark the top of its plan ladder — [Splashtop pricing](https://www.splashtop.com/pricing)
- Apollo's clipboard sync and pairing by web UI from any mobile device — [Apollo](https://github.com/ClassicOldSong/Apollo)

### Inferences
Candidates for Glassy Desk, roughly ordered by fit to its model:
1. **Client-exact virtual display, remembered per device.** Addresses a real Mac gap. iPad and iPhone Duo-type aspect ratios are a natural fit.
2. **System audio, then microphone.** Table stakes; Glass's bundled driver shows the Mac mic path.
3. **Hybrid motion and still encoding.** Sharper text without bandwidth waste.
4. **Pencil pressure and tilt to Mac tablet events.** Beats Splashtop on Mac.
5. **Scoped one-time guest links.** Cheaper and more flexible than Parsec's model.
6. **WebRTC direct no-VPN mode, plus Tailscale pairing.** Fills the most obvious competitive hole.
7. **Reboot survival kit.** Wake-on-LAN, authrestart and Tahoe FileVault SSH unlock guidance.
8. **Agent access with human approval on the iPad.** A novel angle: approve or pause a Mac agent from the phone. It is early, and demand is unproven.
9. **Live latency meter.** Glass shows one; it builds trust and aids troubleshooting.

**Watch item:** Glass is a close technical match, free and MIT-licensed, and has a very similar name and a domain containing "glassdesk". At 164 stars on the repo read, traction is modest, but search confusion and trademark questions deserve a look.

### Gaps
- Adoption and traction for Glass beyond 164 stars, forks and an update around 30 Oct 2026 could not be measured. Stars across forks were not added up.
- No other Tailscale-native or new Mac-focused open source project with meaningful traction surfaced beyond Glass. SlipStream's host is Windows — [WebRTC Remote Desktop](https://github.com/DanielChrobak/WebRTC-Remote-Desktop). Others may exist; the [GitHub topic page](https://github.com/topics/remote-desktop?l=swift&o=desc&s=updated) was not fully reviewed.
- Glass's claims were not independently tested and its website changelog was not read.
