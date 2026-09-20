# Mixed-version compatibility for the update after iOS 2.1

## Release boundaries

- Released iOS baseline: tag `2.1`, commit `fb65dadba73b5d94ca77ded2d15bc97e50389983`.
- Released Mac baseline: 0.2.13 (17), built from `3e13148ac52d5e638e805db8f86227a485a4a522`, as recorded in the [release verification](../releases/macos-0.2.13-verification.md).
- Upcoming app changes: `344e87d` (Accessibility refresh) and `7ba972f` (sleep/display recovery).

The app version numbers are independent. Either app can be updated first; this
release does not require matching app versions or introduce a pairing migration.

| iPhone/iPad | Mac | Behavior |
| --- | --- | --- |
| Updated | 0.2.13 | The connection protocol is compatible. Fast Connection gains configured Wake-on-LAN and clearer display messages on iOS. The Mac's existing Accessibility and sleep/capture bugs remain until it is updated. |
| 2.1 | Updated | The connection protocol is compatible. Mac permission refresh and capture/listener recovery improvements apply. iOS still uses its older display messages and has no Fast Connection Wake-on-LAN controls. |
| Updated | Updated | Both sets of improvements are available. |

Wake-on-LAN requires a compatible, configured Mac and a usable local network
path. Updating only iOS can send a wake packet to an older Mac, but cannot repair
that Mac app's capture recovery. macOS can still withhold capture until unlock.
The changes do not alter Standard VNC.

## Code checks

- `HostProtocol.swift` is unchanged from Mac 0.2.13, and `GlassyStreamWire.swift`
  is unchanged from iOS 2.1. The framing, version 1 handshake, authentication,
  encryption, H.264 envelopes, input formats, and capability values are unchanged.
- All six runtime status values already exist on both released peers. In iOS
  2.1, both the session controller and video renderer already pause their video
  deadlines for `displayUnavailable` and `captureFailed`, then resume them when
  the host returns to `starting` or `streaming`. Those implementations are unchanged.
- Status delivery remains explicitly negotiated through the `adaptiveStream`
  capability and initial client feedback. Older clients that do not subscribe
  are not sent unsupported status messages.
- Device authorization storage and the client's resume-credential format and
  Keychain namespace are unchanged. Ordinary signed app updates do not require
  re-pairing as part of this release.

## Repeatable transport verification

```sh
python3 script/performance/run_stream_audit.py \
  --compatibility released-client --legacy-revision 2.1
python3 script/performance/run_stream_audit.py \
  --compatibility released-host --legacy-revision 3e13148
```

Each mode compiles the chosen release's transport, wire types, credential types,
and relevant support declarations against the other peer's working-tree source.
It does not substitute the current decoder into the older client. Only the
temporary server's binding changes: localhost, an ephemeral port, no Bonjour.
The runner uses optimized whole-module compilation, matching the app's Release
configuration. On this Swift 6.4 toolchain, the standalone per-file `-O` fixture
rejected valid pairing codes; both `-Onone` and whole-module `-O` accepted them.
No production normalization code or historical peer source was changed to make
the test pass.

The fixture checks a real encrypted TCP session with one-time-code pairing, then
disconnects and resumes without supplying the code. Each session checks all six
status values and a return to streaming; exact mouse, scroll, key, Unicode text,
and clipboard payloads; quality selection; cursor coordinates; video configuration
and keyframe bytes; ping/pong; and clean disconnect. Credentials and host device
storage are confined to the fixture. No desktop capture, OS input injection, or
production Keychain access occurs.

Results on 2026-09-20, using Swift 6.4 and optimized whole-module compilation:

| Check | Result |
| --- | --- |
| iOS 2.1 transport + current Mac transport | Passed pairing and saved-credential resume; all six statuses; 14 exact input packets; two video keyframes; two pongs; quality and cursor checks; zero errors. |
| Current iOS transport + Mac 0.2.13 transport | Passed the same checks with zero errors. |
| Pre-adaptive client + current host (`--compatibility legacy-client`) | Passed encrypted authentication, 20 video frames, text input and pong; zero unnegotiated status messages or errors. |
| Current client + pre-adaptive host (`--compatibility legacy-host`) | Passed the same checks with zero errors. |

The pre-adaptive checks use the existing baseline
`485335bc393c173d5f6e39cd5ef73932036ee6fa`. No app behavior changes were needed
for this compatibility audit; the changes are a reusable verification fixture
and release documentation.

This verifies transport interoperability, not physical sleep/wake, TCC dialogs,
or rendered video on an iPhone. The [physical acceptance checks](sleep-wake-recovery-2026-09-12.md#physical-acceptance-checks)
remain part of signed-build release validation.

For future releases, rerun the matrix against the latest shipped version of each
app independently. Any new message or incompatible payload needs explicit
capability negotiation and a fallback for an older peer; an app-version bump
alone is not permission to change protocol version 1.
