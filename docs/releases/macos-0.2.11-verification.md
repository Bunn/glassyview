# Mac 0.2.11 (15) release verification

Published September 7, 2026 from app source commit
`7892edfb5acf128c972179f7fe66440c2075ed97`.

- [Public release](https://github.com/Bunn/GlassyDesk-Host/releases/tag/v0.2.11) is published, not a draft or prerelease.
- The universal arm64/x86_64 app retains the existing Developer ID, bundle identifier, production Keychain storage and Sparkle public key.
- Apple accepted app and installer notarization. Stapled tickets, code signatures, Gatekeeper and the app mounted from the installer passed release-pipeline validation.
- The Sparkle ZIP signature and public ZIP/DMG download bytes were verified against the local release artifacts.
- The [production appcast](https://glassydesk-host.pages.dev/glassy-host/appcast.xml) matched the generated feed with the expected content type and cache headers. Distribution feed commit: `69f077283f3853a5719a4a3450490f4a75f8e4c5`.
- Release receipt: `dist/publish-0.2.11-02a6eba1/state.json`; installer receipt: its `dmg/state.json`. Both record completion and accepted notarization. Deployment used the existing Cloudflare OAuth session. These local receipts are excluded from version control.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `GlassyHost-0.2.11.zip` | 5,870,782 | `5803422ce0a833ef05b6846625f54a3f706d3bf92c657b9cb8a3d374baa4bcbd` |
| `GlassyDesk-0.2.11.dmg` | 6,831,836 | `3c6706721169dba706795d42dc123f33fbadb346f1a6a2ee8d81c0112ab42933` |
| `glassy-host/appcast.xml` | — | `d600f18d4f7ca9c90cefde6774eb37cab86f23bc615aa17757425b7f201c7faf` |

The final notarized app was installed at the existing `/Applications/Glassy Host.app` path. Deep signature verification, stapler validation and Gatekeeper assessment passed; Gatekeeper reports `Notarized Developer ID`. Its executable code sections match the tested candidate for both architectures and its Info.plist is unchanged; signing/export changes the signature hash. The running app reports Ready to connect and retains the three existing iPad approvals. The temporary simulator approval was revoked after testing.

The [Mac download page](https://bunn.dev/glassydesk/mac/) displays version 0.2.11 and both download links target its DMG. Website commit `932ecc0b9e7b589436587eebdc0494f560ebf41a` was pushed to `Bunn/bunn.github.io`; GitHub Pages reports it built, and the live page was verified in the browser.

See [streaming regression validation](../md/streaming-regression-2026-09-07.md) for the two reproduced failures, 149 iOS and 142 Mac test results, compatibility checks, constrained-network measurements and the live Mac-to-simulator session. The client reconnect fix requires installing the updated iPhone/iPad app. No physical iPad was connected and no iOS build was published in this repair. iCloud and persistence work remain excluded.
