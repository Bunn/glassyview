# Mac 0.2.10 (14) release verification

Published September 7, 2026 from app source commit
`dbb60ac34cd0948a43ba11a27a18dbfb1fa46306`.

- [Public release](https://github.com/Bunn/GlassyDesk-Host/releases/tag/v0.2.10) is published, not a draft or prerelease.
- The universal arm64/x86_64 app targets macOS 14+, retains the existing Developer ID/update identity and selects production Keychain storage.
- Apple accepted app and installer notarization. Stapled tickets, code signatures, Gatekeeper, and the app mounted from the installer passed release-pipeline validation.
- Sparkle ZIP signature matches the app's existing public key. Public ZIP and DMG downloads were byte-verified against the signed local artifacts.
- [Production appcast](https://glassydesk-host.pages.dev/glassy-host/appcast.xml) matched the generated feed with RSS content type and non-caching headers. Distribution feed commit: `1c2ddfe97806bdb302a0dcc693770988ca88d51b`.
- Release receipt: `dist/publish-0.2.10-2fd3eda6/state.json`; installer receipt: its `dmg/state.json`. Both record completion. These local receipts are intentionally excluded from version control.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `GlassyHost-0.2.10.zip` | 5,866,990 | `71434594c32fba6792f9a7e9e9d483aa9808387858aba4aad2096f9266fbe170` |
| `GlassyDesk-0.2.10.dmg` | 6,822,682 | `cef6b9f6132148f43e96756ef26cb3670af7fb467a14034c56bc54ac57b7be10` |
| `glassy-host/appcast.xml` | — | `6a0adfec188471d5f198c69a4f51afa49dffb6fd1f067bac27e557d7e04213ab` |

The saved Cloudflare API token was rejected with HTTP 401. An existing Wrangler
OAuth session had access to the configured account and completed deployment of
the same feed. No signing key, artifact, approval scope or stored credential was
replaced. The release tooling now documents an explicit local OAuth recovery
mode; API-token authentication remains the default for unattended CI. An official
`--resume --cloudflare-oauth` check confirmed the completed receipt records the
mode without rebuilding or republishing. All 87 release-tool tests passed.

The Mac landing page and policy/terms corrections were committed and published
through `Bunn/bunn.github.io`. The policy distinguishes version 1.3's revised
analytics controls from earlier iOS behavior. This does not publish the iOS app
or change App Store Connect privacy answers.

See [hardening validation](../md/launch-hardening-2026-09-07.md) for tests,
performance evidence, the excluded iCloud/persistence work, and the private Store
and physical-device checks still required before broad iOS launch.
