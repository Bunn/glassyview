# User complaints and unmet needs in remote desktop apps (iPhone, iPad, Mac)

Method and evidence limits, applying to every section below (notes compiled 2026-11-03):

- **App Store sample:** I pulled the public US App Store review feed (most recent, up to 150 per app) for Screens 5, Jump Desktop, RealVNC Viewer, Moonlight, RustDesk, AnyDesk, TeamViewer and Splashtop. Filtered to reviews dated 2024-01-01 or later, that gave 801 reviews, 485 of them rated 3 stars or lower. I also read about 30 Astropad Workbench reviews separately (not in the counts). Feed example: [Jump feed](https://itunes.apple.com/us/rss/customerreviews/page=1/id=364876095/sortby=mostrecent/json).
- **Bias in that sample:** US store only, and capped, so the windows differ: AnyDesk and TeamViewer cover only about 1 to 2 years, Splashtop has only 29 reviews since 2024. Reviews skew negative. These are not market shares or rates.
- **Reddit was not reachable.** reddit.com blocked the fetch tools, the search tool and direct requests, so **no Reddit thread was read**. r/macmini, r/MacStudio, r/ipad, r/iPadPro, r/selfhosted, r/homelab and r/macapps are unverified. This is the largest gap. Treat "absent here" as "not checked on Reddit", not "not a complaint".
- **Other coverage:** Hacker News comments came from the Algolia API. MacRumors coverage is thin (one on-topic thread read). Jump Desktop's support forum returned 403, so those items rest on search snippets only and are marked.
- **Quotes:** findings are paraphrased, with one short direct quote. Dates are ISO. App Store citations link to the app page, and the date identifies the review.
- **Frequency tags:** RECURRING = at least 5 independent reports or at least 2 source types. SOME = 2 to 4 reports. ANECDOTE = a single report.

## What are the most common complaints across App Store reviews, forums and Hacker News?

### Takeaway
The loudest complaint volume is about paying and signing in (paywalls, subscription resentment, sign-outs), followed by "it will not connect and does not say why" and breakage after OS or app updates. The product-specific opportunities are keyboard and pointer fidelity, sessions that die when you switch apps, and the shrinking gap around display-matched headless use.

### Cited Findings

**Keyword counts across the 485 reviews rated 3 stars or lower, 2024 onward.** Counts are keyword matches, so they are approximate and reviews can match several themes. "Account" is inflated by AnyDesk scam stories mentioning bank accounts.

| Theme | Low-rated hits | Most affected |
|---|---|---|
| Scam or fraud warning | 62 | AnyDesk 58 |
| Account, sign-in, verification | 60 | TeamViewer 18, AnyDesk 17, Screens 12 |
| Paywall, subscription, price | 58 | Screens 24, RealVNC 10, AnyDesk 9, TeamViewer 8 |
| Cannot connect or setup failure | 55 | Jump 16, TeamViewer 11, RealVNC 9 |
| Broke after update or OS release | 40 | RealVNC 13, Jump 9, RustDesk 6, Screens 6 |
| Freeze, disconnect, crash | 39 | RustDesk 11, Screens 8, AnyDesk 8 |
| Keyboard and modifier keys | 31 | RealVNC 12, Jump 7 |
| Mouse, trackpad, gestures | 29 | Jump 9, RealVNC 6 |
| "Abandoned" or no updates | 16 | Jump 7 |
| Resolution and fit | 15 | Screens 5, AnyDesk 4 |
| Commercial-use flag | 10 | TeamViewer 10 |
| Audio | 10 | Screens 3, Jump 3 |
| File transfer and clipboard | 9 | RealVNC 4 |
| Battery drain | 8 | Jump 7 |
| iPhone Duo missing or broken (launched about 2026-10-23) | 8 | RustDesk 3, Jump 2, TeamViewer 2 |
| Multi-display handling | 6 | Jump 3 |
| Wake-on-LAN | 3 | Jump 2 |

**Silent connection failure (RECURRING).**
- Setup failed with no diagnostics given — [App Store: Screens, 2025-12-15](https://apps.apple.com/us/app/id1663047912).
- Bounced to the server list with no alert after a macOS update — [App Store: Jump, 2026-08-10](https://apps.apple.com/us/app/id364876095).
- Mac shows online after subscribing, but no connection, error or troubleshooting path — [App Store: Workbench, 2026-04-18](https://apps.apple.com/us/app/id6758788573).
- A traveller asks for a reachability check so they learn of failure before they need access — [App Store: Screens, 2025-12-20](https://apps.apple.com/us/app/id1663047912).

**Update and OS regressions (RECURRING).**
- iPadOS 26 stopped Magic Keyboard input — [App Store: RealVNC, 2025-09-19 and 2025-09-23](https://apps.apple.com/us/app/id352019548).
- Ctrl and Esc still not passing through months later — [App Store: RealVNC, 2025-11-21](https://apps.apple.com/us/app/id352019548).
- Update made the app crash on launch on iOS 27 or Duo — [App Store: RustDesk, 2026-10-30 and 2026-10-31](https://apps.apple.com/us/app/id1581225015).
- A Screens update reportedly broke clicks and scrolling, and the reviewer left for Workbench — [App Store: Screens, 2026-06-11](https://apps.apple.com/us/app/id1663047912).

**Session fragility and freezes (RECURRING).**
- Visual freeze about every minute on iPad Pro to M4 mini — [App Store: Screens, 2026-06-11](https://apps.apple.com/us/app/id1663047912).
- Switching apps for 15 seconds forces a reconnect, sometimes a new sign-in — [App Store: Workbench, 2026-06-12](https://apps.apple.com/us/app/id6758788573).
- Asks to stop auto-disconnecting 5 seconds after switching apps — [App Store: AnyDesk, 2025-08-25](https://apps.apple.com/us/app/id1176131273).

**Battery drain in background (RECURRING, Jump-specific).** Six separate Jump reviews report this, one citing 70% lost in 4 hours and another saying 5 to 10 times RealVNC's usage — [App Store: Jump, 2025-03-09, 2025-12-09, 2026-02-06, 2026-03-30, 2026-04-24, 2026-05-28](https://apps.apple.com/us/app/id364876095). Jump 10's beta notes list a 10-minute default background runtime on iOS, which looks like a response — [Jump changelog](https://changelog.jumpdesktop.com/jump-desktop-10-beta-QXilW).

**"Abandoned app" anxiety (RECURRING, Jump, now possibly stale).** Reviews through 2026 worry about no updates in 2 years — [App Store: Jump, 2025-12-08, 2026-03-02, 2026-04-24, 2026-08-23](https://apps.apple.com/us/app/id364876095). But Jump's current App Store build is 10.17.1, released 2026-11-03 — [iTunes lookup](https://itunes.apple.com/lookup?id=364876095&country=us). A single review also mourns pinch-to-zoom removal and another a three-step display switch, which suggests a big recent rewrite brought its own regressions — [App Store: Jump, 2026-10-17 and 2026-10-22](https://apps.apple.com/us/app/id364876095).

**iPhone Duo support as a new battleground (RECURRING, last two weeks).**
- Requests for Duo support: [Jump, 2026-10-23 to 2026-10-27](https://apps.apple.com/us/app/id364876095); [AnyDesk, 2026-10-25](https://apps.apple.com/us/app/id1176131273); [TeamViewer, 2026-10-26 and 2026-10-27](https://apps.apple.com/us/app/id692035811); [RustDesk, 2026-10-27](https://apps.apple.com/us/app/id1581225015); [Workbench, 2026-10-26](https://apps.apple.com/us/app/id6758788573).
- A reviewer credits Screens with full Duo support within 24 hours — [App Store: Screens, 2026-10-24](https://apps.apple.com/us/app/id1663047912).
- Workbench 1.4 also lists Duo support — [AlternativeTo, October 2026](https://alternativeto.net/news/2026/10/astropad-workbench-1-4-adds-terminal-access-iphone-duo-support-and-mac-to-mac-file-transfer/).

**Apple's absence is a standing grievance (SOME).**
- Direct quote: "The remote access story for macOS is absolute sadness" — [HN comment, 2026-07-10](https://news.ycombinator.com/item?id=48858352).
- Same frustration about no first-party Screen Sharing app on iPhone or iPad, with FaceTime remote control called convoluted — [HN comment, 2026-10-16](https://news.ycombinator.com/item?id=50118620).
- A MacStories reviewer wants the same, since Workbench needs a fallback — [MacStories, about May 2026, date inferred from image filenames](https://www.macstories.net/reviews/astropad-workbench-rethinks-remote-mac-control-for-ai-agents/).

**Performance dissatisfaction beyond the leaders (ANECDOTE, but telling).** An HN user's project idea is a light, fast link from iPad or MacBook Air to a Mac mini, because Splashtop and Apple VNC feel slow — [HN comment, 2026-05-14](https://news.ycombinator.com/item?id=48136849).

### Inferences
- "Tell me why it failed and what to do" looks like a cheap, under-served differentiator: several apps fail silently, and connection problems are the largest non-commercial theme.
- App-switch survival is a phone and iPad need competitors have not solved, and it trades directly against battery drain. A session that suspends cleanly and resumes instantly addresses both.
- Same-week support for new Apple hardware and OS versions earns visible goodwill and punishes laggards. Glassy Desk's existing Duo work should be a marketing point while competitors are still being asked for it.

### Gaps
- Reddit sentiment, as noted above. No reliable volume comparison between apps is possible from this sample.
- Mac App Store reviews for Mac clients were not pulled separately. Chrome Remote Desktop has no findable iOS listing in the search API, so no review data. Parsec has no reviews here because I found no iOS app listing to pull; I did not verify whether an iOS client exists.

## What pain is specific to headless Macs?

### Takeaway
FileVault after reboot and non-Retina default resolution are the two defining headless problems. Both are shifting fast: Tahoe added SSH unlock (a multi-step flow no client appears to have made simple in this evidence), and Jump and Workbench now create matched virtual displays, so display matching is becoming table stakes rather than a differentiator.

### Cited Findings

**FileVault and login after reboot (RECURRING, multiple source types).**
- Before Tahoe, a rebooted FileVault Mac needed physical password entry. Jeff Geerling documents the macOS 26 fix: enable Remote Access (SSH) beforehand, SSH in with admin credentials to unlock, and only then use Screen Sharing. Early Wi-Fi-only unlock failed; he reports 26.5 fixed it — [Geerling, 2025-09-19](https://www.jeffgeerling.com/blog/2025/you-can-finally-manage-macs-filevault-remotely-tahoe/).
- MPU forum users report Tahoe enabling FileVault on upgrade without them noticing, leaving a headless mini unreachable after reboot and blocked from auto-login. One poster calls the VPN-then-SSH route a multi-step hassle, and both chose to keep FileVault off. One poster later allows he may have missed a notice screen — [MPU Talk, 2025-09-25](https://talk.macpowerusers.com/t/tahoe-and-filevault/42942).
- An HN user wishes to avoid physical login after an outage and is weighing a KVM device — [HN comment, 2025-09-19](https://news.ycombinator.com/item?id=45296499).
- Commercial demand exists: Password Utility from Twocanoes offers authenticated restart at $10 per device per year — [9to5Mac, 2026-01-17](https://9to5mac.com/2026/01/17/password-utility-solves-the-filevault-reboot-headache-for-remote-macs/).
- Older background: a neighbour had to log in to a Mac for VNC to work, and users disagree on whether VNC needs a logged-in session even without FileVault — [TidBITS Talk, 2022-07 to 2023-03, older than the requested window](https://talk.tidbits.com/t/remote-login-after-reboot/19583).

**Daemons that need a logged-in user (SOME).**
- Sunshine added to Login Items stays unavailable until login, so the user enabled automatic login — [LizardByte discussion, 2026-01-12](https://github.com/orgs/LizardByte/discussions/777).
- A relay client signed out after a crash cannot be signed back in remotely, so the reviewer waits until home — [App Store: Screens, 2024-06-02](https://apps.apple.com/us/app/id1663047912).
- Low-confidence source: a community guide says the standalone Tailscale app daemon needs a logged-in user, and recommends a Homebrew launchd service — [claudskills, undated, unverified](https://claudskills.com/skills/tailscale-mosh-recover/SKILL.md).

**Wrong or fuzzy resolution (RECURRING).**
- Vendor claim: Apple Silicon needs no plug because it creates a virtual display, but it defaults to non-Retina 1920×1080 over VNC and Screen Sharing — [Astropad, 2026-06-15, sells a competing product](https://astropad.com/blog/dummy-plug-headless-mac-mini/).
- Jump forum user says a headless Mac mini defaults to 1920×1080 — search snippet only, [Jump iOS Feature Requests](https://support.jumpdesktop.com/hc/en-us/community/topics/200668823-iOS-Feature-Requests?page=2).
- Screens does not fit the iPad's resolution — [App Store: Screens, 2024-05-18](https://apps.apple.com/us/app/id1663047912). Screens lacks dynamic resolution, scaling poorly against a large Mac Studio display — [App Store: Screens, 2025-11-09](https://apps.apple.com/us/app/id1663047912).
- Half the iPad screen letterboxed, needing 2 to 10 reconnects to match — [App Store: Jump, 2025-03-25](https://apps.apple.com/us/app/id364876095).
- A buyer reports a dummy display not appearing over VNC on M-series Macs (ANECDOTE) (search snippet, exact listing not verified) — [Newegg listing](https://www.newegg.com/p/2S7-08BC-002K0).
- Apple's High Performance mode tops out at 4K, or 1920×1080 with HiDPI — [9to5Mac, 2026-02-05](https://9to5mac.com/2026/02/05/how-to-use-macos-high-performance-screen-sharing-for-lower-latency-and-better-color-video/).

**Competitors are closing this.**
- Jump 10 beta notes describe headless-capable virtual displays, including on iOS, matching device resolution — [Jump changelog, date ambiguous, 03/02/2026](https://changelog.jumpdesktop.com/jump-desktop-10-beta-QXilW).
- Reviewers praise the shipped result, on iPad and iPhone — [App Store: Jump, 2026-09-25 and 2026-10-23](https://apps.apple.com/us/app/id364876095).
- Workbench's Unified Display is praised — [App Store: Workbench, 2026-04-24](https://apps.apple.com/us/app/id6758788573).

**Black screen on connect (SOME).** Other tools gave only a black screen on a Mac mini, and Jump worked — [App Store: Jump, 2026-10-09](https://apps.apple.com/us/app/id364876095). Black screen from a Mac Studio — [App Store: RealVNC, 2025-08-06](https://apps.apple.com/us/app/id352019548).

**Remote power and wake (SOME).**
- macOS 26.5 adds "Start up when power is connected" on Mac mini 2024+, Mac Studio 2025+ and iMac 2024+, booting about 2 seconds after power returns. FileVault still requires SSH unlock, and a login-window shutdown defeats it — [Geerling, 2026-06-12](https://jeffgeerling.com/blog/2026/power-on-your-mac-remotely).
- Missing Wake-on-LAN is resented — [App Store: Jump, 2025-01-28](https://apps.apple.com/us/app/id364876095); [App Store: Moonlight, 2026-01-25](https://apps.apple.com/us/app/id1000551566).
- Connecting to a sleeping dual-monitor Mac over cellular earns praise — [App Store: Workbench, 2026-04-21](https://apps.apple.com/us/app/id6758788573). Parsec cannot host from a sleeping Mac — [Parsec support](https://support.parsec.app/hc/en-us/articles/4423549357837-Install-Parsec-app-on-macOS).

**Audio routing (SOME).**
- Closing TeamViewer flips a headless music server's output back to internal speakers, attributed to TeamViewer's audio device; removing it fixed things — [MacRumors, 2026-10-07 to 2026-10-13](https://forums.macrumors.com/threads/mac-mini-changes-sound-output.2491260/).
- No remote audio in Screens — [App Store: Screens, 2025-06-16 and 2025-12-26](https://apps.apple.com/us/app/id1663047912).
- Final Cut user could not get sound over Screen Sharing — [Apple Discussions, 2025-02-07](https://discussions.apple.com/thread/255961650).
- Apple's High Performance mode carries stereo, but is described as Apple Silicon Mac to Mac, with no iOS client mentioned — [9to5Mac, 2026-02-05](https://9to5mac.com/2026/02/05/how-to-use-macos-high-performance-screen-sharing-for-lower-latency-and-better-color-video/).
- A newer app, Tomaco, markets system audio with no virtual driver (vendor claim) — [Tomaco listing](https://mwm.ai/apps/tomaco-remote-desktop/6787690528).

**Curtain and privacy mode reliability (SOME).** A user reports being locked out of a Mac by a stuck curtain, with SSH disabled — [App Store: Screens, 2025-08-21](https://apps.apple.com/us/app/id1663047912). Curtain fails on macOS 27 hosts — [App Store: Screens, 2026-07-28](https://apps.apple.com/us/app/id1663047912). Could not get it working — [App Store: Screens, 2026-02-15](https://apps.apple.com/us/app/id1663047912).

**Sunshine host setup on Apple Silicon (RECURRING within one thread).** Build failures, unusable packages and screen recording permission problems across multiple users from June 2025 to January 2026 — [LizardByte discussion](https://github.com/orgs/LizardByte/discussions/777).

### Inferences
- A guided "survive reboot" flow looks like the sharpest headless wedge: verify Remote Access, state FileVault status, warn if unlock would fail, and offer an SSH pre-boot unlock from the iOS client, then hand off directly to the desktop session. The evidence shows the capability exists and the multi-step flow is the complaint. Whether a competitor already does this needs a check against the feature-matrix research.
- A "headless readiness" check in the macOS companion could cover sleep settings, power-on setting, FileVault, Screen Recording permission, virtual display and audio output, and could warn on the Geerling login-window shutdown edge case.
- Matched virtual displays are no longer enough to differentiate; quality, persistence and reliability of them are.
- Restoring the user's chosen audio output on disconnect is a small, cheap trust feature for music-server users.

### Gaps
- No primary Apple documentation was read for SSH unlock; it rests on Geerling and forum reports.
- No Reddit evidence on dummy plugs; dummy-plug prevalence is unmeasured.

## What pain is specific to using a Mac from a phone-size screen?

### Takeaway
Direct evidence is thinner than expected, since most iPhone complaints in reviews are about connecting, not ergonomics. What exists points to input mode choice, keys that do not reach the Mac, and the on-screen keyboard eating the display, with voice input emerging as a praised escape.

### Cited Findings
- **Touch mode choice (SOME):** direct touch feels clunky on a phone, and the reviewer wants trackpad mode — [App Store: Workbench, 2026-10-28](https://apps.apple.com/us/app/id6758788573); also no trackpad mode — [App Store: Workbench, 2026-04-11](https://apps.apple.com/us/app/id6758788573).
- **Zoom (SOME):** a reviewer says pinch-to-zoom removal makes phone use impossible — [App Store: Jump, 2026-10-22](https://apps.apple.com/us/app/id364876095). Must choose between touch and pinch modes, not both — [App Store: Jump, 2026-02-03](https://apps.apple.com/us/app/id364876095). Dislikes the view shifting as the finger moves, wants resolution control — [App Store: AnyDesk, 2025-11-19](https://apps.apple.com/us/app/id1176131273).
- **Keyboard covering the screen (ANECDOTE, expert):** MacStories says the on-screen keyboard covers most of the remote desktop, and praises dictation plus a zoomable mini map as the fix. It also credits unified display with helping tiny Terminal text — [MacStories, about May 2026](https://www.macstories.net/reviews/astropad-workbench-rethinks-remote-mac-control-for-ai-agents/).
- **Keys not reaching the Mac (RECURRING):**
  - On a screensaver, the limited key set lacked a space bar — [App Store: Jump, 2026-10-03](https://apps.apple.com/us/app/id364876095).
  - Space bar dead in Terminal after an update — [App Store: Jump, 2026-10-17](https://apps.apple.com/us/app/id364876095).
  - Delete typing the letter "a" on iOS — [App Store: Workbench, 2026-09-12](https://apps.apple.com/us/app/id6758788573).
  - Esc closes the session rather than reaching the host, and app switching does not pass through — [App Store: Workbench, 2026-05-06 and 2026-06-25](https://apps.apple.com/us/app/id6758788573).
  - Cmd+Q quits the client instead of the remote app, and iPadOS status bar overlaps the Mac menu bar — [App Store: Jump, 2026-10-21](https://apps.apple.com/us/app/id364876095).
  - Asks for a virtual keyboard aid — [App Store: AnyDesk, 2025-12-17](https://apps.apple.com/us/app/id1176131273).
- **Toolbar stability (ANECDOTE):** moving the Command key in the modifier bar broke one user's muscle memory — [App Store: Screens, 2025-06-23](https://apps.apple.com/us/app/id1663047912).
- **Dedicated edit buttons (ANECDOTE):** requests copy, paste, select all and find buttons, noting Android has them — [App Store: Jump, 2026-01-12](https://apps.apple.com/us/app/id364876095).
- **External pointing devices (SOME):**
  - Missed clicks, no scroll with mouse — [App Store: TeamViewer, 2026-04-28 and 2026-07-31](https://apps.apple.com/us/app/id692035811).
  - Cursor desync — [App Store: Jump, 2026-10-14](https://apps.apple.com/us/app/id364876095).
  - Cursor jumping to a corner triggers hot corners — [App Store: Workbench, 2026-04-09](https://apps.apple.com/us/app/id6758788573).
  - Magic Trackpad gestures do not pass through — [App Store: Jump, 2024-11-03 and 2025-12-16](https://apps.apple.com/us/app/id364876095).
- **Duo folded state (ANECDOTE, adjacent, not remote-specific):** an owner calls closed form very small with the keyboard up, a pocket mode rather than a place to work — [HN comment, 2026-10-30](https://news.ycombinator.com/item?id=50302121).
- **Bright client UI (ANECDOTE):** a request for dark mode for nighttime phone use — [App Store: TeamViewer, 2025-08-28](https://apps.apple.com/us/app/id692035811).

### Inferences
- A phone-first interaction set could be a real wedge: per-context key strip, one-tap quit and switch shortcuts, dictation, window-focused zoom, and easy switching between touch and trackpad modes, rather than one global mode.
- Window-level viewing appears to have appetite: Sill, a project for streaming any Mac window to iPhone and iPad, drew 275 points and 76 comments on HN — [HN listing, 2026-10-16](https://hn.algolia.com/api/v1/search?query=%22Any%20window%20from%20your%20Mac%22&tags=story) for [Sill](https://github.com/Saffsanity/sill). I did not read the project itself or the full thread.

### Gaps
- Older phone-specific reviews exist but predate 2024, so I excluded them. There is no robust frequency data on tiny text or pointer precision on phones. Reddit is the most likely source for this and was unavailable.

## What complaints exist about subscriptions, pricing, free-tier limits, accounts, trust and privacy?

### Takeaway
Pricing resentment is the single most consistent theme for Screens, and "commercial use" flagging drives TeamViewer users to leave. One-time purchase is actively praised, and even Workbench's happy users ask for it. Accounts and cloud relays are a separate irritant, with a vocal group wanting no vendor in the path.

### Cited Findings

**Subscription and paywall (RECURRING).**
- Official Screens prices are $3.99 per month, $24.99 per year, $119 lifetime — [Edovia FAQ](https://help.edovia.com/en/screens-5/faq/s5-pricing). **Conflict:** recent reviewers cite $179 and $199 lifetime — [App Store: Screens, 2026-09-15 and 2026-10-28](https://apps.apple.com/us/app/id1663047912). The FAQ may be stale, or prices may vary. Verify in the app.
- Paying a subscription for purely local use is the specific grievance — [App Store: Screens, 2026-05-16 and 2026-10-28](https://apps.apple.com/us/app/id1663047912). The same for RealVNC, with a reviewer citing $169 per year and wanting a local-only one-time purchase — [App Store: RealVNC, 2026-03-28](https://apps.apple.com/us/app/id352019548).
- Being surprised by a paywall after setup or download — [App Store: Screens, 2025-01-03, 2025-08-28, 2026-01-28, 2026-09-11](https://apps.apple.com/us/app/id1663047912).
- Screens 4 owners feel abandoned: no upgrade path, and one has zero trust that a lifetime purchase will stick — [App Store: Screens, 2024-12-01, 2025-01-31, 2026-09-15](https://apps.apple.com/us/app/id1663047912).
- Workbench is $10 per month or $50 per year, with 20 free minutes per day — [TechCrunch, 2026-04-08](https://techcrunch.com/2026/04/08/astropads-workbench-reimagines-remote-desktop-for-ai-agents-not-it-support/). Users ask for one-time pricing, and an existing Screens user finds $50 per year uncompelling — [App Store: Workbench, 2026-04-08 and 2026-10-27](https://apps.apple.com/us/app/id6758788573).
- Price as a positive: Jump's one-time purchase, thousands of hours of use — [App Store: Jump, 2026-07-12](https://apps.apple.com/us/app/id364876095). Jump costs $14.99 on the US store — [iTunes lookup](https://itunes.apple.com/lookup?id=364876095&country=us). An MPU forum post notes the Mac and iOS versions are bought separately (search snippet, exact thread not verified) — [MPU Talk](https://talk.macpowerusers.com/t/best-remote-desktop-solution/28748).

**Personal users treated as commercial (RECURRING, TeamViewer).**
- TeamViewer's "commercial use" community thread runs to at least 169 pages — [TeamViewer community](https://community.teamviewer.com/English/discussion/8284/commercial-use-connection-time-out/p169) (dates of pages not verified).
- Ten low-rated reviews in about 17 months mention it, including personal and family setups — [App Store: TeamViewer, 2025-06-19, 2025-07-21, 2025-08-16](https://apps.apple.com/us/app/id692035811).
- One reviewer cites about $600 a year for occasionally helping parents — [App Store: TeamViewer, 2026-06-23](https://apps.apple.com/us/app/id692035811).
- A switcher moved to RustDesk after being flagged while reaching their own laptop — [App Store: RustDesk, 2026-08-05](https://apps.apple.com/us/app/id1581225015).
- AnyDesk free tier limits are murky across sources, mostly competitor blogs — [HelpWire](https://helpwire.app/blog/anydesk-session-time-limit/). One complaint describes 5-minute disconnects — [SikayetVar, 2025-09](https://www.sikayetvar.com/en/anydesk-us/anydesk-free-version-forces-long-wait-times-and-disconnects-every-5-minutes).

**Accounts and sign-in (RECURRING).**
- Workbench constantly signs users out; one dislikes email verification and wants to stay signed in — [App Store: Workbench, 2026-04-15, 2026-05-18](https://apps.apple.com/us/app/id6758788573).
- Screens Connect 2FA emails slow or hard to reach, and an account loop that blocked both login and re-registration — [App Store: Screens, 2024-11-18, 2025-10-22, 2025-10-25](https://apps.apple.com/us/app/id1663047912).
- Tired of creating accounts — [App Store: Jump, 2026-05-25](https://apps.apple.com/us/app/id364876095). Verification email never arrived; Google sign-in loop — [App Store: Jump, 2025-11-24, 2026-09-16](https://apps.apple.com/us/app/id364876095).
- No-account use is praised — [App Store: AnyDesk, 2025-01-13](https://apps.apple.com/us/app/id1176131273).
- Multi Apple ID setups break subscription recognition (SOME) — [App Store: Screens, 2026-06-15 and 2026-07-03](https://apps.apple.com/us/app/id1663047912).

**Trust and privacy (RECURRING, varied).**
- AnyDesk's reviews are dominated by scam warnings: 58 of its 150 recent reviews, with victims told to install it by fake support staff — [App Store: AnyDesk, 2024-09 to 2026-10](https://apps.apple.com/us/app/id1176131273). RealVNC gets one too — [App Store: RealVNC, 2026-04-10](https://apps.apple.com/us/app/id352019548).
- No trusted cloud host needed via Tailscale is praised — [App Store: Screens, 2026-09-28](https://apps.apple.com/us/app/id1663047912). Self-hosted and untracked is praised — [App Store: RustDesk, 2026-06-27](https://apps.apple.com/us/app/id1581225015).
- An HN thread around TeamViewer's June 2024 security breach recommends moving to Jump — [HN comment, 2024-06-27](https://news.ycombinator.com/item?id=40816009).
- Unanswered data deletion request (ANECDOTE) — [App Store: Screens, 2026-05-01](https://apps.apple.com/us/app/id1663047912).

### Inferences
- Free local access with paid remote, or a fair one-time price, would hit the most-repeated Screens and RealVNC complaint directly. The specific phrase behind the anger is paying for "local" connections.
- Whatever pricing is chosen, disclose it before setup, since surprise after setup is a recurring trigger. Promise upgrade terms explicitly, given the broken-lifetime fear.
- A no-account path over LAN and Tailscale matches both the "no more accounts" and "no cloud in the path" groups. Sign-in session persistence matters for anyone who has an account, because being locked out remotely defeats the product.
- For Glassy Desk's own positioning: explicit "personal use is never flagged" wording and a clear statement that it is not a support-scam tool (no incoming-stranger flow) could be meaningful, given how much trust damage the category carries.

### Gaps
- No verified rate of TeamViewer false flags. No primary terms were read for AnyDesk or TeamViewer. Whether Glassy Desk's free tier design matches user tolerance cannot be inferred from this; I found no evidence on how users react to Workbench's 20-minute allowance specifically.

## What workarounds do people use, and which could become product features?

### Takeaway
Users are assembling a stack of about five third-party tools to get a dependable headless Mac. Display, reboot unlock, overlay networking and health checking are the parts most plausible to absorb; hardware recovery is not.

### Cited Findings

| Workaround | Evidence | Signal | Feature candidate |
|---|---|---|---|
| BetterDisplay, BetterDummy, SwitchResX for HiDPI on headless | [BetterDisplay site](https://betterdisplay.pro/) advertises headless at any resolution (custom setups paid); [MPU Talk, 2024-05-03](https://talk.macpowerusers.com/t/what-do-you-recommend-for-remote-ipad-desktop-to-mac/37086) describes Jump plus SwitchResX | SOME | Built-in matched virtual display, per-device profiles |
| HDMI dummy plugs | [Astropad, 2026-06-15](https://astropad.com/blog/dummy-plug-headless-mac-mini/) (vendor); [HN, 2026-06-27](https://news.ycombinator.com/item?id=48701845) one user's dummy plug failed to stop sleep (laptop) | SOME | Tell users plainly they do not need one on Apple Silicon |
| `fdesetup authrestart` for planned restarts | [TidBITS Talk, 2023-03-28](https://talk.tidbits.com/t/remote-login-after-reboot/19583) | SOME | "Restart and come back" button with clear FileVault consent |
| SSH pre-boot unlock | [Geerling, 2025-09-19](https://www.jeffgeerling.com/blog/2025/you-can-finally-manage-macs-filevault-remotely-tahoe/) | RECURRING | Integrated unlock screen in the client |
| Password Utility | [9to5Mac, 2026-01-17](https://9to5mac.com/2026/01/17/password-utility-solves-the-filevault-reboot-headache-for-remote-macs/) | ANECDOTE (paid tool exists) | Evaluate; stored credentials carry security trade-offs |
| Turn FileVault off | [MPU Talk, 2025-09-25](https://talk.macpowerusers.com/t/tahoe-and-filevault/42942) | RECURRING | Explain the trade-off, make keeping it on viable |
| Tailscale | Praised repeatedly, [App Store: Screens, 2026-03-18 to 2026-10-04](https://apps.apple.com/us/app/id1663047912); [HN, 2026-04-01](https://news.ycombinator.com/item?id=47597168) | RECURRING | Native Tailscale discovery (Screens already has this, so it is table stakes) |
| Manual ports, no UPnP | [App Store: Screens, 2026-06-23](https://apps.apple.com/us/app/id1663047912) | ANECDOTE | Keep manual configuration for power users |
| Smart plug for power cycling | [Lemmy comment](https://ui.lemm.ee/post/15695359/6461217), general servers, undated; [HN, 2025-09-03](https://news.ycombinator.com/item?id=45114523), homelab zones | SOME, not Mac-specific | Guide with the macOS 26.5 power-on setting; optional smart plug integration is speculative |
| Hardware KVM | [HN, 2025-09-19](https://news.ycombinator.com/item?id=45296499), considering; [HN, 2026-08-15](https://news.ycombinator.com/item?id=49306233), GL.iNet Comet on an Ubuntu headless machine | ANECDOTE | Not a software feature; note compatibility in docs |
| Bare SSH to restart a hung host app | [App Store: Workbench, 2026-04-22](https://apps.apple.com/us/app/id6758788573) | ANECDOTE | Host watchdog and client-initiated host restart |
| Guided Access to hide the iPadOS status bar | [App Store: Jump, 2026-10-21](https://apps.apple.com/us/app/id364876095) | ANECDOTE | True edge-to-edge handling of the Mac menu bar |
| Auto-login and Login Items for Sunshine | [LizardByte, 2026-01-12](https://github.com/orgs/LizardByte/discussions/777) | SOME | Host runs before login as a system service, where permitted |
| Second app as fallback | [MacStories, about May 2026](https://www.macstories.net/reviews/astropad-workbench-rethinks-remote-mac-control-for-ai-agents/) | ANECDOTE, expert | Fallback path in the same client, for example direct VNC if the fast path fails |

### Inferences
- A combined "headless health" panel on the client could report: reachable over which route, FileVault locked, last boot, host running, display mode and permissions. This addresses the traveller's worry directly (App Store: Screens, 2025-12-20, above).
- Terminal-in-the-same-app is a natural pairing: Workbench 1.4 added terminal access, per [AlternativeTo](https://alternativeto.net/news/2026/10/astropad-workbench-1-4-adds-terminal-access-iphone-duo-support-and-mac-to-mac-file-transfer/), and SSH is already the rescue route.

### Gaps
- **I found no reliable evidence of PiKVM use with Apple Silicon Macs** in the sources reached, and no credible source on Mac-specific smart plug setups. Reddit r/homelab would be the place to check.

## Which non-obvious use cases appear?

### Takeaway
Watching AI agents on an always-on Mac is the fastest-growing use case and has reshaped the market narrative in 2026. Family support is durable and underserved since TeamViewer's flagging. iPad-as-Mac-laptop is the strongest loyal segment. Audio-sensitive creative work is an open gap.

### Cited Findings
- **AI agent monitoring (RECURRING, some vendor-driven):**
  - Astropad's pitch is built on Mac mini agent demand — [HN launch comment, 2026-04-10](https://news.ycombinator.com/item?id=47712974); [TechCrunch, 2026-04-08](https://techcrunch.com/2026/04/08/astropads-workbench-reimagines-remote-desktop-for-ai-agents-not-it-support/).
  - Organic reports: watching a local agent on an old mini — [App Store: Workbench, 2026-06-11](https://apps.apple.com/us/app/id6758788573). Calling Screens a necessity in the agentic era — [App Store: Screens, 2026-09-28](https://apps.apple.com/us/app/id1663047912). Vibe coding on the go — [App Store: Jump, 2026-05-08](https://apps.apple.com/us/app/id364876095).
- **iPad as thin client for a Mac mini (RECURRING):** using iPad plus headless mini instead of a MacBook — [HN, 2026-04-06](https://news.ycombinator.com/item?id=47666137); [App Store: Jump, 2025-06-25](https://apps.apple.com/us/app/id364876095); [App Store: Workbench, 2026-06-04](https://apps.apple.com/us/app/id6758788573). An iOS developer notes being unable to deploy to the iPad remotely unless on the same Wi-Fi — [HN, 2026-03-02](https://news.ycombinator.com/item?id=47223412).
- **Family tech support (RECURRING):** long-distance help for parents — [App Store: Screens, 2025-01-21 and 2025-05-04](https://apps.apple.com/us/app/id1663047912); [App Store: TeamViewer, 2025-08-20 and 2026-01-25](https://apps.apple.com/us/app/id692035811). Parents were once tricked by a fake support remote tool — [HN, 2024-04-23](https://news.ycombinator.com/item?id=40134331). iOS limits: a helper can only see a device's screen, not control it — [App Store: TeamViewer, 2025-08-24](https://apps.apple.com/us/app/id692035811).
- **View-only monitoring (SOME):** a broadcaster needs view-only for on-air assets — [App Store: Jump, 2025-11-03](https://apps.apple.com/us/app/id364876095), and Jump 10's notes add View Only Mode — [Jump changelog](https://changelog.jumpdesktop.com/jump-desktop-10-beta-QXilW). Others: farm computer — [App Store: TeamViewer, 2026-08-11](https://apps.apple.com/us/app/id692035811). SCADA access — [App Store: Jump, 2026-10-11](https://apps.apple.com/us/app/id364876095).
- **Video and 3D (SOME):** checking long renders from an iPhone — [App Store: TeamViewer, 2026-05-19](https://apps.apple.com/us/app/id692035811). Blender on iPad — [App Store: Workbench, 2026-05-06](https://apps.apple.com/us/app/id6758788573). Final Cut with audio remains unsolved for one asker — [Apple Discussions, 2025-02-07](https://discussions.apple.com/thread/255961650).
- **Music (SOME):** headless Mac mini music library and servers — [App Store: Screens, 2025-01-28](https://apps.apple.com/us/app/id1663047912); [MacRumors, 2026-10](https://forums.macrumors.com/threads/mac-mini-changes-sound-output.2491260/). Logic via High Performance Screen Sharing — [9to5Mac, 2026-02-05](https://9to5mac.com/2026/02/05/how-to-use-macos-high-performance-screen-sharing-for-lower-latency-and-better-color-video/). No evidence of iPad-driven Ableton or Logic workflows from a Mac Studio was found. Microphone and input wishes — [App Store: Jump, 2024-07-09 and 2025-06-25](https://apps.apple.com/us/app/id364876095).
- **Vision Pro as a client (RECURRING, niche):** multi-window Mac and homelab access praised — [App Store: Screens, 2026-04-15](https://apps.apple.com/us/app/id1663047912); letterboxing and cursor complaints — [App Store: Jump, 2025-12-16 and 2026-07-23](https://apps.apple.com/us/app/id364876095).
- **Emergency use (ANECDOTE):** laptop with a broken screen used via phone — [App Store: Splashtop, 2026-05-18](https://apps.apple.com/us/app/id382509315). Remoting in from a hospital stay — [App Store: TeamViewer, 2026-02-01](https://apps.apple.com/us/app/id692035811).
- **iPad or iPhone as second display:** only a Jump forum thread title surfaced, not read — [Jump forum](https://support.jumpdesktop.com/hc/en-us/community/posts/28809980054669/comments/28825168005005). Low signal here.

### Inferences
- Notifications when an agent job finishes or stalls, a dictation-first prompt box, and a low-bandwidth peek or view-only mode would fit agent watchers without being a full remote session. Astropad owns this story in marketing, so differentiation needs to be concrete.
- Family help could be a cheap, free-feeling plan with safety rails (known contacts only) to contrast with the scam-tainted tools. This is my inference and I found no direct request for such a plan.
- A view-only mode is low effort, already requested and now matched by Jump.

### Gaps
- No usable data on the size of any segment. Second-display and kiosk or digital-signage use on Mac found almost no evidence.

## What do users praise, so strengths worth matching are clear?

### Takeaway
Users most reward "it just works, every time", effortless setup, a sharp display that feels native, and a fast developer response. Trust and fair pricing earn loyalty that survives other flaws.

### Cited Findings
- **Reliability and consensus (RECURRING):**
  - Jump is the most recommended in a thread spanning 2024 to 2025 — [MPU Talk](https://talk.macpowerusers.com/t/what-do-you-recommend-for-remote-ipad-desktop-to-mac/37086).
  - It succeeded after everything else failed on a Mac mini — [App Store: Jump, 2026-02-08 and 2026-10-09](https://apps.apple.com/us/app/id364876095).
  - Considered more foolproof than Screens for Macs — [App Store: Screens, 2025-12-26](https://apps.apple.com/us/app/id1663047912).
- **Guided setup (SOME):** automatically stepping through permissions and restarts — [App Store: Jump, 2026-08-05](https://apps.apple.com/us/app/id364876095). Contrast Screens reviewers calling setup a huge hassle — [App Store: Screens, 2024-10-07](https://apps.apple.com/us/app/id1663047912).
- **Retina-quality matched display (RECURRING):** [App Store: Jump, 2026-09-25 and 2026-10-23](https://apps.apple.com/us/app/id364876095); [App Store: Workbench, 2026-04-24](https://apps.apple.com/us/app/id6758788573).
- **Native polish and Apple-feel UX (RECURRING):** a user says Screens gets usability right, with customizable toolbars and adaptive quality praised — [App Store: Screens, 2026-03-18 and 2026-08-19](https://apps.apple.com/us/app/id1663047912). A Workbench user calls it a break from utilitarian, ugly tools — [App Store: Workbench, 2026-04-09](https://apps.apple.com/us/app/id6758788573).
- **Latency that makes you forget it is remote (SOME):** [App Store: Workbench, 2026-05-06](https://apps.apple.com/us/app/id6758788573); RustDesk over Tailscale called smooth, better than Screens — [HN, 2026-04-01](https://news.ycombinator.com/item?id=47597299) and [HN, 2026-04-01](https://news.ycombinator.com/item?id=47597168).
- **Tailscale integration (RECURRING):** many Screens reviews, for example [App Store: Screens, 2026-09-14 and 2026-10-04](https://apps.apple.com/us/app/id1663047912).
- **Fast adoption and responsive support (SOME):** Duo in 24 hours — [App Store: Screens, 2026-10-24](https://apps.apple.com/us/app/id1663047912). Quick support — [App Store: Screens, 2024-01-29 and 2025-01-21](https://apps.apple.com/us/app/id1663047912). Contrast email-only slowness — [App Store: Jump, 2026-01-13](https://apps.apple.com/us/app/id364876095).
- **Voice input and unified window view (ANECDOTE, expert):** [MacStories, about May 2026](https://www.macstories.net/reviews/astropad-workbench-rethinks-remote-mac-control-for-ai-agents/).
- **File transfer as a gap that users notice (SOME):** the same review faults Workbench for no Finder-to-Finder transfer at launch ([MacStories](https://www.macstories.net/reviews/astropad-workbench-rethinks-remote-mac-control-for-ai-agents/)), and a Screens review lists it too ([App Store: Screens, 2025-06-16](https://apps.apple.com/us/app/id1663047912)). Grabbing a file is praised — [App Store: Jump, 2026-09-30](https://apps.apple.com/us/app/id364876095).
- **Store ratings at time of lookup (2026-11-03):** Workbench 4.83 (217 ratings), RealVNC 4.76 (15,348), Splashtop 4.68 (4,095), TeamViewer 4.67 (44,935), Screens 4.52 (598), AnyDesk 4.49 (28,380), Jump 4.49 (1,712), Moonlight 4.22 (672), RustDesk 3.92 (99) — [iTunes lookup example](https://itunes.apple.com/lookup?id=6758788573&country=us).

### Inferences
- The bar to match: guided setup like Jump, Retina matching like Jump and Workbench, Tailscale and customizable toolbars like Screens, plus dictation like Workbench.
- The gaps left open by these leaders: pricing that does not punish local use, reboot recovery, reliable key passthrough, and app-switch-safe sessions.

### Gaps
- Praise on Reddit and in Mac App Store reviews was not captured. I could not determine which Jump features named in beta notes (for example, View Only) are in the public 10.x build. High aggregate star ratings conflict with the negative recent-review sample, which reflects the selection bias stated at the top.
