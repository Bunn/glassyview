# Mac 0.2.12 (16) release verification

Published September 7, 2026 from app source commit
`a8d5f9b9154931120d3c08373676ddb042d54762`.

- [Public release](https://github.com/Bunn/GlassyDesk-Host/releases/tag/v0.2.12) is published, not a draft or prerelease.
- The universal arm64/x86_64 app retains the existing Developer ID, bundle identifier, production Keychain storage and Sparkle public key.
- Apple accepted app and installer notarization. The pipeline verified app and installer signatures, stapled tickets, Gatekeeper acceptance, the app mounted from the installer, the Sparkle ZIP signature and public download bytes.
- The [production appcast](https://glassydesk-host.pages.dev/glassy-host/appcast.xml) matched the generated feed and expected headers. Distribution feed commit: `94cc58684e86a8b2b8d499d236923780d47c9fe2`.
- Local receipts `dist/publish-0.2.12-9d10d478/state.json` and its `dmg/state.json` both record completion and accepted notarization. Deployment used the existing Cloudflare OAuth session. Receipts are excluded from version control.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `GlassyHost-0.2.12.zip` | 5,873,998 | `8d6457d0d5eb62b20b406f711ac4c79b5c524dc25aca833de1c5fcfdd9f25258` |
| `GlassyDesk-0.2.12.dmg` | 6,833,342 | `f028e365805d8e5f894d90f96fcf038a0829e10f8a3b308a1db0dc8392afdf86` |
| `glassy-host/appcast.xml` | — | `8f1b0a26e2693a4e292cd3ec9df2e990dc6baf9933d95957f04acf5c2e492a1d` |

The existing Mac 0.2.11 installation discovered 0.2.12 through its normal Check for Updates menu. Sparkle downloaded the update, offered Install and Relaunch, and successfully relaunched the updated host. `/Applications/Glassy Host.app` now reports 0.2.12 (16); deep signature verification, stapler validation and Gatekeeper assessment passed, with `Notarized Developer ID` acceptance. The app reports Ready to connect and retains all three existing iPad approvals. A verified backup of the previous app was retained locally before updating.

The [Mac download page](https://bunn.dev/glassydesk/mac/) displays 0.2.12 and both download links target its DMG. Website commit `19a2465e93649d4453868980de36e9218695201b` was pushed to `Bunn/bunn.github.io`; GitHub Pages reports it built and the live page was verified in the browser.

See [streaming continuity validation](../md/streaming-continuity-2026-09-07.md) for the reproduced black-image gap, callback burst overflow and host format-ordering race, plus 156 iOS and 144 Mac test results and real codec/network checks. The main black-flash fix requires iOS **1.3 (4)** from the updated source. No physical iPad was connected and no iOS build was published in this repair. iCloud and persistence work remain excluded.
