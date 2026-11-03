# Supervising AI coding agents and long-running jobs from a phone (state as of 3 November 2026)

Source reliability: official docs and changelogs were read directly unless marked otherwise. "[excerpt]" means the claim came from a search-result excerpt and the full page was not read. "[vendor]" means the source sells a competing or related product. Older information carries its date. Glassy Desk's own code and feature set were not reviewed for these notes, so product implications are stated generally.

## What does each tool offer, how much does it cost, and how does it connect to the computer?

### Takeaway
Since February 2026 every major agent vendor has shipped its own phone remote control, normally included in the existing subscription and usually connected through a vendor relay. That has made conversation-level supervision a free commodity. The paid opening is outside the chat, and Astropad Workbench already sells a remote desktop aimed directly at this use case.

### Cited Findings

**First-party agent apps**

| Tool | What the phone can do | Cost | Connection | Key limits |
|---|---|---|---|---|
| Claude Code Remote Control | Steer a local session from the Claude app or claude.ai/code; send images and files; subagent progress stays in sync | Included in Pro, Max, Ultra, Team and Enterprise; API keys not supported; Owner must enable on Team and Enterprise | Relay: outbound HTTPS only, no inbound ports, all traffic through the Anthropic API over TLS | Local process must keep running; some commands are local-only ([docs](https://code.claude.com/docs/en/remote-control)) |
| Codex in ChatGPT | Start or continue chats, steer, approve commands, review diffs, test results, terminal output and screenshots, get notifications, switch hosts ([docs](https://learn.chatgpt.com/docs/remote-connections)) | Preview on all plans including Free and Go at the May 2026 launch ([Android Authority, excerpt](https://www.androidauthority.com/openai-unveils-codex-on-chatgpt-mobile-3667443/)); current docs list no tiers | Secure relay; QR pairing from the desktop app; SSH hosts can also be added | Host must be awake, online and signed in; a closed Mac laptop also needs an external display ([docs](https://learn.chatgpt.com/docs/remote-connections)) |
| Cursor for iOS | Launch agents, choose models, voice input, slash commands, diffs, follow-ups, merge PRs ([TestingCatalog, June 2026](https://www.testingcatalog.com/cursor-releases-its-ios-app-for-vibe-coding-on-the-go/)); see and reply to local agents ([changelog, 6 Oct 2026](https://cursor.com/changelog)) | Public beta for paid plans at launch ([TestingCatalog](https://www.testingcatalog.com/cursor-releases-its-ios-app-for-vibe-coding-on-the-go/)); Remote Control on by default except Enterprise ([changelog](https://cursor.com/changelog)) | Cloud VMs for cloud agents; pairing approved in desktop app for local agents | Local agents need the computer on and online; keep-awake needs power and an open lid ([changelog](https://cursor.com/changelog)) |
| GitHub Copilot and GitHub Mobile | Approve or deny tool, path and URL requests, answer questions, approve plans, submit prompts ([docs, excerpt](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/about-remote-control)); start sessions by voice from Mobile ([changelog, 28 Oct 2026](https://github.blog/changelog/2026-10-28-work-from-anywhere-with-a-new-connected-copilot-cloud-experience/)) | New cloud experience on paid Copilot plans only; sandbox billing begins November 2026 ([changelog](https://github.blog/changelog/2026-10-28-work-from-anywhere-with-a-new-connected-copilot-cloud-experience/)) | CLI remote GA May 2026 ([changelog](https://github.blog/changelog/2026-05-18-remote-control-for-copilot-cli-sessions-now-generally-available-on-mobile-web-and-vs-code/)); local devices registered as environments; VS Code `code agent host` reported ([Visual Studio Magazine, 29 Oct 2026, excerpt](https://visualstudiomagazine.com/articles/2026/10/29/github-lets-developers-control-vs-code-ai-agents-from-their-phones.aspx)) | Host must stay online; admin policy needed on Business and Enterprise ([docs, excerpt](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/about-remote-control)) |

**Superseded launch facts to avoid repeating**
- Claude Remote Control launched as a Pro and Max research preview with one remote session ([TechRadar, Feb 2026, excerpt](https://www.techradar.com/pro/anthropic-reveals-remote-control-a-mobile-version-of-claude-code-to-keep-you-productive-on-the-move?rand=141)). Current docs add Ultra, Team and Enterprise, and server mode defaults to 32 concurrent sessions ([docs](https://code.claude.com/docs/en/remote-control)).
- Codex mobile launched with Mac hosts only ([Android Authority, May 2026, excerpt](https://www.androidauthority.com/openai-unveils-codex-on-chatgpt-mobile-3667443/)). Current docs list macOS or Windows hosts, subject to rollout ([docs](https://learn.chatgpt.com/docs/remote-connections)).

**Other Anthropic surfaces**
- Dispatch messages a task from the phone and can spawn a Desktop session; Channels forward Telegram, Discord or iMessage into a running session; Slack starts cloud sessions ([Remote Control docs](https://code.claude.com/docs/en/remote-control)).
- Channels remain a research preview ([docs](https://code.claude.com/docs/en/channels)).

**Third-party agent clients**
- Happy: MIT-licensed, reuses existing subscriptions, supports Claude Code, Codex, Grok and any ACP agent, has an end-to-end encrypted relay (`happy-server`) and its own APNs/FCM push worker, about 24.5k stars at time of reading ([GitHub](https://github.com/slopus/happy)).
- Omnara: FAQ cited as free with unlimited sessions; local component plus remote apps; optional cloud migration when the laptop is offline; two-way voice; encryption not specified. All of this comes from a competitor's July 2026 comparison ([SeaWork, vendor](https://seawork.ai/en/blogs/omnara-vs-happy-vs-seawork/)). Omnara's site returned only a tagline when fetched ([Omnara](https://remote.omnara.com)).
- Early open-source Omnara is described as no longer maintained ([search excerpt, Grass, vendor](https://codeongrass.com/blog/is-there-a-mobile-app-for-claude-code/)). Excerpt attribution is approximate; confirm before quoting.
- SeaWork: free app, pay for model usage only; local daemon with an end-to-end encrypted relay ([SeaWork, vendor](https://seawork.ai/en/blogs/omnara-vs-happy-vs-seawork/)).
- Codync: MIT-licensed, free including the relay; approve from iPhone, Mac, Linux or terminal; launched on Product Hunt in October 2026 ([Hunted](https://hunted.space/product/codync)).

**Terminal route**
- Termius: Starter free; Pro $10/month billed annually; Team $20 and Business $30 per seat per month billed annually. Only AI autocomplete is listed, with no AI agent or voice features on the pricing page ([Termius](https://termius.com/pricing)).
- Blink Shell: free download with in-app purchases ([App Store](https://apps.apple.com/app/id1594898306)), from $19.99/year per a directory listing ([FitGap, excerpt](https://us.fitgap.com/products/blink-shell)). Its move to subscriptions frustrated earlier one-time buyers ([Moshi, vendor, excerpt](https://getmoshi.app/articles/blink-shell-alternatives)).
- Moshi: mosh terminal built for agents; `moshi-hook` reports approvals, questions, completions, tool errors and usage from Claude Code, Codex, OpenCode, Cursor, Kimi and Qwen ([Moshi, Jan 2026, vendor](https://getmoshi.app/articles/best-setup-coding-agent-phone)).
- Common DIY stack: Tailscale, mosh or SSH, tmux, and a phone terminal. The Moshi guide describes Tailscale as free for personal use up to 100 devices ([Moshi, Jan 2026, vendor](https://getmoshi.app/articles/best-setup-coding-agent-phone)). A first-hand example uses tmux, mosh and self-hosted ntfy over WireGuard ([rogs.me, Feb 2026](https://rogs.me/2026/02/claude-code-from-the-beach-my-remote-coding-setup-with-mosh-tmux-and-ntfy/)).

**Screen-level direct competitor**
- Astropad Workbench: full Mac control and terminal on iPhone and iPad; virtual display matching the client device; mini-map; Pencil; privacy curtain; dictation; intelligent sleep; 11-region relay; AES-256 end-to-end encryption; macOS 15+ and iOS 26+ ([Astropad](https://astropad.com/product/workbench/)).
- Workbench pricing conflict: 20 free minutes a day in both sources, but unlimited is $14.99/month or $79.99/year on the [current product page](https://astropad.com/product/workbench/) versus $10/month or $50/year at launch ([TechCrunch, April 2026](https://techcrunch.com/2026/04/08/astropads-workbench-reimagines-remote-desktop-for-ai-agents-not-it-support/)). Treat the product page as current; it suggests a price rise.

**Job-notification tools**
- ntfy: HTTP PUT or POST to a topic with no sign-up; the topic name acts as the password; up to three action buttons including HTTP callbacks ([docs](https://docs.ntfy.sh/publish/)). Self-hosted iOS delivery needs an upstream server, otherwise it can take hours ([docs](https://docs.ntfy.sh/config/)).
- Pushover: $4.99 one-time per platform, 30-day trial, 10,000 messages per month; Teams $5 per user per month ([Pushover](https://pushover.net/pricing)).
- terminal-notifier: macOS-only local notifications with actions and replies. It cannot post over SSH or from a root launchd daemon, and the page does not describe phone delivery ([GitHub](https://github.com/julienXX/terminal-notifier)).

### Inferences
- Charging for "see and answer your agent" will be hard, because the agent vendors bundle it. A remote desktop should price and message against what these apps cannot show.
- Workbench validates willingness to pay in this niche, and its current price gives a reference point. Its positioning overlaps Glassy Desk's "watch AI agents finish" promise directly.
- Relay versus direct is a real trust differentiator. The first-party tools route through vendors and Workbench uses its own relay, while DIY stacks can stay on a private network.

### Gaps
- Current list prices for Claude, ChatGPT, Cursor and Copilot plans were not re-verified. Only plan eligibility is reported.
- Moshi's price, ntfy Pro's price and Omnara's encryption design could not be confirmed.
- The Copilot docs and VS Code Agent Host details come from excerpts. The Visual Studio Magazine page returned 403, and OpenAI's launch post also returned 403.

## How do people get alerted that a job finished or an agent needs approval, and what hooks exist?

### Takeaway
Three alert layers now coexist: built-in vendor push, third-party apps fed by agent hooks, and DIY webhooks to ntfy or Pushover. Claude Code and Codex both expose a blocking `PermissionRequest` hook, so a third party can build real approve and deny, not just alerts.

### Cited Findings

**Built-in push**
- Claude Code has two toggles, "Push when Claude decides" and "Push when actions required", with no per-event configuration. It skips pushes while you are active at the connected terminal, and iOS Focus modes can suppress them ([docs](https://code.claude.com/docs/en/remote-control)).
- Codex's phone flow includes notifications ([docs](https://learn.chatgpt.com/docs/remote-connections)).
- GitHub Mobile shows in progress, waiting for input, idle and finished states ([changelog, 8 Jul 2026](https://github.blog/changelog/2026-07-08-github-mobile-live-notifications-for-copilot-cli-sessions/)).

**Claude Code hooks** ([docs](https://code.claude.com/docs/en/hooks))
- `Notification` matchers include `permission_prompt`, `idle_prompt`, `agent_needs_input` and `agent_completed`. It has no decision control and is for side effects.
- `PermissionRequest` can allow or deny and can modify tool input.
- `Stop` fires when Claude finishes responding and includes the last assistant message; `StopFailure` covers API errors.
- Handlers can be `command`, `http`, `mcp_tool`, `prompt` or `agent`.

**Codex hooks** ([docs](https://learn.chatgpt.com/docs/hooks))
- Events include `PermissionRequest`, `Stop`, `PreToolUse`, `PostToolUse`, `SessionStart`, `SessionEnd` and `Interrupt`.
- `PermissionRequest` can allow, deny or defer to the normal prompt.

**Other push-in paths**
- Claude Channels can relay permission prompts through Telegram, Discord or iMessage if the channel declares that capability, and anyone allowlisted on the channel can approve tool use ([docs](https://code.claude.com/docs/en/channels)).

**Community patterns built on these hooks**
- claude-pager: Notification hook to ntfy, with approve and deny buttons that send keystrokes back through tmux, so Claude must run inside tmux ([GitHub, excerpt](https://github.com/FilipCondac/claude-pager)).
- claude-watch: HTTP hooks to a Node bridge on the Mac; `PermissionRequest` blocks up to 10 minutes while the watch or phone decides ([GitHub](https://github.com/shobhit99/claude-watch)).
- Agentfy: one webhook in the Claude Code config, or a plugin ([App Store](https://apps.apple.com/app/id6757966311)).
- Moshi offers a curl webhook in `CLAUDE.md` or `AGENTS.md` as the fallback for scripts and unhooked agents ([Moshi, Jan 2026, vendor](https://getmoshi.app/articles/best-setup-coding-agent-phone)).

### Inferences
- A notification alone does not solve the job here. The gap in all of these alerts is the next step: a tap usually opens a log or a chat, not the screen where the problem is.
- A small Mac-side helper could register hooks and deep link a push straight to the right Mac, and ideally to the relevant window. That would turn hooks into an entry point for the remote screen.
- A generic "run this when done" webhook would also cover renders and builds, which no agent hook sees. That matches the wording of Glassy Desk's paywall promise.

### Gaps
- Cursor and Copilot hook surfaces were not reviewed in primary docs. Moshi's claim to support Cursor via hooks is vendor-sourced and dated January 2026.
- Codex's `notify` setting was not covered on the hooks page, and its Notifications page was not read.

## What do these tools fail at that a full remote screen handles?

### Takeaway
They supervise the conversation and whatever the agent chooses to report, not the machine. No vendor document advertises streaming a live desktop to the phone. The clearest openings are OS dialogs, GUI apps and visual verification, but agent computer use and auto-captured screenshots are narrowing part of this gap.

### Cited Findings

**Evidence for the screen gap**
- Astropad's CEO argues operators still need the screen, for example to approve a dialog: "there are times you've got to see what's happening on your Mac" ([TechCrunch, April 2026](https://techcrunch.com/2026/04/08/astropads-workbench-reimagines-remote-desktop-for-ai-agents-not-it-support/)). This is an interested party.
- Agent setup itself raises GUI prompts. The Claude iMessage channel needs a macOS Full Disk Access prompt and an Automation prompt clicked "OK" on the Mac ([docs](https://code.claude.com/docs/en/channels)).
- Some prompts are not forwarded at all. Claude's mid-session Fable usage-credits consent prompt appears only where the session runs, and commands like `/plugin` and `/resume` are local-only ([docs](https://code.claude.com/docs/en/remote-control)).
- A developer running agents on a remote Mac for iOS builds, simulator tests and computer use still opens Screen Sharing to see the desktop ([DEV Community, excerpt](https://dev.to/juandastic/my-coding-agents-now-have-a-remote-mac-16fo)).
- A hosted-Mac provider recommends SSH for the agent plus RustDesk or VNC to see Xcode or the Simulator ([MacRent, vendor, excerpt](https://www.macrent.cloud/cloud-mac-for-claude-code)).
- Screen capture and input depend on the GUI login session, so one guide keeps tmux running inside that session through a LaunchAgent ([Developers Digest, updated Oct 2026](https://www.developersdigest.tech/blog/spare-mac-claude-code-control-guide)).

**Evidence that the gap is narrowing**
- Codex's phone view includes screenshots, and Computer Use runs on the host ([docs](https://learn.chatgpt.com/docs/remote-connections)).
- An agent can send back a recording of the web app and simulator for review ([DEV Community, excerpt](https://dev.to/juandastic/my-coding-agents-now-have-a-remote-mac-16fo)).
- serve-sim streams the simulator to a browser with a control channel for agents ([Thaki Cloud, excerpt](https://thakicloud.com/tech-blog/en/dev/serve-sim-ios-simulator-web/)).
- macsim lets Linux agents drive a Mac's iOS Simulator, but not physical devices ([GitHub, excerpt](https://github.com/MSliwa01/macsim)).
- Cursor's cloud flow reportedly offers a web preview before merge ([KuCoin News, June 2026, low-quality aggregator](https://www.kucoin.com/news/flash/cursor-and-openclaw-launch-mobile-apps-on-same-day-competing-on-cloud-vs-local-ai-strategies)).

**Limits a remote desktop shares**
- Sleep, network loss or quitting stops Codex access ([docs](https://learn.chatgpt.com/docs/remote-connections)), and Cursor has similar needs ([changelog](https://cursor.com/changelog)). Workbench addresses reachability with "intelligent sleep" ([Astropad](https://astropad.com/product/workbench/)).
- Headless Apple silicon Macs fall back to a blurry low-resolution display, and Workbench advertises a virtual display to fix it ([Astropad guide, vendor, excerpt](https://astropad.com/blog/openclaw-mac-mini/)).
- Screen Recording permission can misbehave without a display ([agensi.io or similar guide, excerpt](https://www.agensi.io/learn/openclaw-mac-mini)). Excerpt attribution is approximate; verify before citing.

**What the agent tools do well, for balance**
- Reading diffs, approving commands and sending a follow-up are structured and work well on a small screen, and the same state syncs across devices ([Claude docs](https://code.claude.com/docs/en/remote-control); [Codex docs](https://learn.chatgpt.com/docs/remote-connections)).

### Inferences
Likely screen-only situations, reasoned from the above and not measured:
- macOS privacy (TCC), keychain, login and installer dialogs.
- Xcode signing errors, Simulator behaviour, and device-specific UI checks.
- Logged-in browser sessions, CAPTCHAs and OAuth flows that block an agent.
- Design tools such as Figma or Blender viewports, and render or video previews.
- A wedged or crashed agent where the chat surface has gone offline, which is the point when a supervising app has nothing to show.
- Non-agent jobs that have no chat at all.

Positioning suggestion:
- Frame the product as "the escape hatch when the chat runs out", complementary to first-party apps rather than a replacement. Most of these users will keep the free agent app for routine approvals.
- Reading a terminal over remote desktop on an iPhone is worse than a native chat view. Do not compete there.
- Agents capturing their own screenshots eat the "just let me look" case. Durable value lies in acting on what the agent cannot, especially OS-level prompts and human sign-in steps.

### Gaps
- I found no survey or usage data on how often supervisors need the full screen.
- No substantial Hacker News or Reddit thread specifically on this gap was found. The evidence is first-person posts plus vendor claims.
- Jump Desktop, Screens and other established remote desktop apps' agent-specific moves did not surface and should be covered elsewhere.

## How common is the "Mac mini at home running agents" setup in 2026, and which tools do those people use?

### Takeaway
It is a real and visible trend tied to OpenClaw and to demand strong enough for press and Apple's own comments, but there is no reliable count of users. Shortage reporting is confounded by a memory squeeze. Typical setups mix SSH, Tailscale, tmux and macOS Screen Sharing, with the agent vendor's phone app on top.

### Cited Findings

**Demand signals**
- OpenClaw had about 247,000 GitHub stars as of May 2026. Mac mini and Mac Studio inventory was reported sold out across the US for weeks, with a months-long wait on the base $599 model and high-RAM configurations pulled from the store ([The Next Web, 11 May 2026](https://thenextweb.com/news/claude-mac-mini-openclaw-ai-agents-shortage)).
- Tim Cook said Mac mini and Mac Studio may take several months to reach supply-demand balance ([MobileSyrup, 1 May 2026, excerpt](https://mobilesyrup.com/2026/05/01/mac-studio-and-mini-could-be-in-short-supply-for-months/)). The Next Web frames his earnings comments as a supply problem, while excerpts elsewhere quote him saying Apple under-called demand. Treat agent-driven demand as plausible but not an Apple-stated cause.
- The only size estimate found is secondhand: Bloomberg reportedly counts one operator among several thousand small-business operators running similar setups ([The Next Web](https://thenextweb.com/news/claude-mac-mini-openclaw-ai-agents-shortage)).
- Memory scarcity is a confounder, and IDC projects PC shipments down 11.3% in 2026 ([The Next Web](https://thenextweb.com/news/claude-mac-mini-openclaw-ai-agents-shortage)).
- Mac mini demand has risen particularly in China for agents such as OpenClaw ([TechCrunch, April 2026](https://techcrunch.com/2026/04/08/astropads-workbench-reimagines-remote-desktop-for-ai-agents-not-it-support/)).
- Buyers reportedly use a dedicated machine to isolate OpenClaw's broad permissions ([Yahoo Finance, excerpt](https://finance.yahoo.com/sectors/technology/article/apple-is-facing-mac-mini-supply-constraints-as-ai-and-openclaw-developers-buy-up-tiny-desktops-221232805.html)). Excerpt attribution is approximate.

**Tools those people use**
- Guides recommend Remote Login, Screen Sharing, Tailscale, tmux, disabled sleep and the OpenClaw daemon ([Astropad, vendor, excerpt](https://astropad.com/blog/openclaw-mac-mini/); [agensi.io, excerpt](https://www.agensi.io/learn/openclaw-mac-mini); [GitHub gist, excerpt](https://gist.github.com/timstew/f5e49d8133f45e6eae950b4fcb2d93d8)). Most of these are vendor or affiliate-style guides.
- The Developers Digest guide uses SSH, Claude Remote Control, optional Tailscale and Screen Sharing on an isolated spare Mac, and warns about the risk of passwordless sudo and skipped permissions ([Developers Digest, updated Oct 2026](https://www.developersdigest.tech/blog/spare-mac-claude-code-control-guide)).
- Several Hacker News commenters were skeptical of round-the-clock agents ([same guide's HN summary](https://www.developersdigest.tech/blog/spare-mac-claude-code-control-guide)). Security-driven alternatives to OpenClaw also exist ([HN item](https://news.ycombinator.com/item?id=47004203), not read in full).
- OpenClaw's mobile app is a companion node to a local gateway, supplying camera, microphone, location and push. Screenshots and photos are off by default ([KuCoin News, June 2026, low-quality aggregator](https://www.kucoin.com/news/flash/cursor-and-openclaw-launch-mobile-apps-on-same-day-competing-on-cloud-vs-local-ai-strategies)).
- Hosted alternatives are also sold, such as cloud Macs for Claude Code ([MacRent, vendor](https://www.macrent.cloud/cloud-mac-for-claude-code)).

### Inferences
- This audience suits a remote desktop better than most: the Mac has no monitor, so a phone or iPad may be its only screen, and macOS prompts have nowhere else to be answered. High-quality headless display support looks like table stakes, not a bonus.
- Not all of these buyers are developers. Small-business operators may value a visual fallback more than a terminal, though evidence is anecdotal.
- Treat market size as unknown. "Several thousand" and star counts should not be read as a customer count.

### Gaps
- I found no credible figure for active home Mac mini agent hosts, nor a split of consumer, developer and small business.
- May 2026 shortage reports were not re-confirmed for November, so current Mac mini availability is unknown.
- The Bloomberg report was not read directly.

## What do Live Activities, Dynamic Island, or Apple Watch integrations look like in this category?

### Takeaway
Live Activities are already expected, with GitHub shipping them first-party and many small apps offering them. Actionable approval from the Lock Screen or wrist is rarer and mainly found in third-party tools. No source found describes a remote desktop app using Live Activities.

### Cited Findings

**First-party**
- GitHub Mobile: Live Activities on iOS 17.2+ for remote Copilot CLI sessions, showing in progress, waiting for input, idle and finished; tap opens session logs. Android 16+ gets live updates ([changelog, 8 Jul 2026](https://github.blog/changelog/2026-07-08-github-mobile-live-notifications-for-copilot-cli-sessions/)).
- Cursor: a Lock Screen Live Activity reportedly appears when an agent needs merge confirmation, per a single low-quality aggregator ([KuCoin News, June 2026](https://www.kucoin.com/news/flash/cursor-and-openclaw-launch-mobile-apps-on-same-day-competing-on-cloud-vs-local-ai-strategies)). Unconfirmed: TestingCatalog's launch article does not mention it ([TestingCatalog](https://www.testingcatalog.com/cursor-releases-its-ios-app-for-vibe-coding-on-the-go/)).
- Claude Remote Control docs describe push notifications and do not describe Live Activities on the section read ([docs](https://code.claude.com/docs/en/remote-control)).

**Third-party**
- Vigil Companion (launched 2026; free, requires Vigil for Mac): shows each session in the Dynamic Island and on the Lock Screen. The Mac starts, updates and ends the Live Activity so it stays current with the iPhone app closed, carried over the user's own iCloud, with no account or developer server, per the maker ([Product Hunt](https://www.producthunt.com/products/vigil-companion)).
- Agentfy: Lock Screen and Dynamic Island states "Cooking" and "Your Move"; Live Activity requires Pro at $2.99/month, $19.99/year or $39.99 lifetime; free tier has 100 alerts ([App Store](https://apps.apple.com/app/id6757966311)). No approval feature described.
- Codync: follows work from Dynamic Island and Lock Screen; Apple Watch support appears only in a user comment ([Hunted](https://hunted.space/product/codync)).
- Agentsroom: one Live Activity across agents, also on Apple Watch, with Lock Screen answers working for Claude Code ([search excerpt](https://agentsroom.dev/features/live-activities)). Page fetch failed; unverified.
- Moshi: Live Activities and Dynamic Island; Watch shows an inbox and usage rings; approve, deny and answer from the wrist need Pro ([Moshi, Jan 2026, vendor](https://getmoshi.app/articles/best-setup-coding-agent-phone)).
- claude-watch: open-source watchOS app with live tool activity, dictation, haptics, and tappable approval options; about 627 stars ([GitHub](https://github.com/shobhit99/claude-watch)).
- Vibe Notch: approve and deny in the Mac notch, not on a phone ([search excerpt](https://docsearch.algolia.com/mcp/docs/repo/farouqaldori/vibe-notch)).

### Inferences
- A Live Activity is low-cost to match and increasingly expected for a product promising to "watch" jobs finish. Vigil's Mac-driven approach shows a route that does not need the iOS app running or a developer server, although this rests on the maker's description.
- A differentiated version could show job status plus a recent thumbnail of the relevant window, with a tap that opens the live screen. None of the reviewed apps offers this, but absence from these sources does not prove nobody does.
- Lock Screen approval raises a real safety question: an accidental tap could authorize a destructive command. Any such feature would need authentication and clear context.

### Gaps
- OpenAI's and Anthropic's Live Activity or Watch support could not be confirmed either way.
- Adoption figures for these small apps were not available, and long-term maintenance is uncertain.
- Exact APNs Live Activity budget constraints were not researched.

## What novel concepts appear?

### Takeaway
The category is moving from "remote terminal" to ambient, multi-surface supervision: voice-first prompts, wrist and Lock Screen decisions, agent-operated GUIs, and session handoff to the cloud. Screen-aware agents are the idea most relevant to a remote desktop, as both threat and opportunity.

### Cited Findings

**Voice**
- GitHub Mobile accepts voice task descriptions ([changelog, 28 Oct 2026](https://github.blog/changelog/2026-10-28-work-from-anywhere-with-a-new-connected-copilot-cloud-experience/)), and Cursor iOS has voice input ([TestingCatalog](https://www.testingcatalog.com/cursor-releases-its-ios-app-for-vibe-coding-on-the-go/)).
- Workbench dictates prompts into Mac apps or the terminal ([Astropad](https://astropad.com/product/workbench/)).
- Moshi offers three speech engines: Apple on-device, local Whisper and its own cloud ([Moshi, Jan 2026, vendor](https://getmoshi.app/articles/best-setup-coding-agent-phone)).
- Omnara and Happy are cited for two-way or real-time voice ([SeaWork, July 2026, vendor](https://seawork.ai/en/blogs/omnara-vs-happy-vs-seawork/)); Happy's README as read did not mention voice ([GitHub](https://github.com/slopus/happy)).
- claude-watch uses watchOS dictation ([GitHub](https://github.com/shobhit99/claude-watch)).

**Approve from anywhere**
- Wrist approvals through claude-watch ([GitHub](https://github.com/shobhit99/claude-watch)) and Moshi Pro ([Moshi, vendor](https://getmoshi.app/articles/best-setup-coding-agent-phone)).
- Notification buttons through claude-pager ([GitHub, excerpt](https://github.com/FilipCondac/claude-pager)).
- Approvals by chat through Claude Channels ([docs](https://code.claude.com/docs/en/channels)).

**Screen-aware and computer-using agents**
- Claude computer use launched in March 2026 as a macOS research preview, tried after direct integrations, and paired with Dispatch; Anthropic warned it is slower and imperfect ([Anthropic blog, excerpt](https://claude.com/blog/dispatch-and-computer-use)). Current status past preview was not confirmed.
- Sources conflict over Dispatch's reach: one secondary source describes a Cowork sandbox without full desktop control ([mejba.me, excerpt](https://www.mejba.me/claude-cowork-dispatch-remote)), and Anthropic's post describes screen control ([Anthropic, excerpt](https://claude.com/blog/dispatch-and-computer-use)).
- Codex tasks use the host's Computer Use setup ([docs](https://learn.chatgpt.com/docs/remote-connections)).

**Device and session concepts**
- Trusted Devices ties remote access to a verified device and recent authentication ([docs](https://code.claude.com/docs/en/remote-control)).
- Presence awareness: `CLAUDE_CLIENT_PRESENCE_FILE` suppresses pushes while you are at the machine ([docs](https://code.claude.com/docs/en/remote-control)).
- Cloud handoff: Omnara session migration when the laptop goes offline ([SeaWork, vendor](https://seawork.ai/en/blogs/omnara-vs-happy-vs-seawork/)) and Cursor moving local sessions to the cloud ([TestingCatalog](https://www.testingcatalog.com/cursor-releases-its-ios-app-for-vibe-coding-on-the-go/)).
- Shared sessions: Happy lets a colleague watch and steer ([GitHub](https://github.com/slopus/happy)).
- Keep-awake as a product: Vigil holds a closed MacBook awake while agents work, with battery and heat safeguards ([Product Hunt](https://www.producthunt.com/products/vigil-companion)).
- Phone as agent sensor: OpenClaw's mobile node ([KuCoin News, low-quality aggregator](https://www.kucoin.com/news/flash/cursor-and-openclaw-launch-mobile-apps-on-same-day-competing-on-cloud-vs-local-ai-strategies)).
- Canvases: Cursor cloud agents produce shareable interactive canvases ([changelog, 16 Oct 2026](https://cursor.com/changelog)).

### Inferences
Ideas worth weighing for a remote desktop, none validated with users:
- Human takeover: when an agent using computer control gets stuck, a notification opens the exact window so a person can resolve it and hand control back. This turns agent computer use from a threat into a source of sessions.
- Watch mode: a low-bandwidth, view-only stream or periodic thumbnail for long jobs, cheaper on battery and data than a full session.
- Attention signals: visual change or idle detection on a chosen window for GUI jobs that have no hook, such as renders. This would be new to the sources reviewed, and technical feasibility has not been assessed.
- Voice into the focused Mac app is already offered by Workbench, so it is parity rather than differentiation.

### Gaps
- No source showed a shipped remote desktop that hands off between a person and an agent, but this search was not exhaustive.
- Whether Dispatch and computer use remain in research preview in November 2026 could not be confirmed, and neither could Anthropic's current plan availability for them.
- X posts were not reachable through these tools, so developer sentiment there is unrepresented.
