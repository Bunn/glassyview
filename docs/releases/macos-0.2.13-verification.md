# Mac 0.2.13 (17) release verification

Published September 7, 2026 from app source commit `3e13148`.

## Feature validation

- `swift test --package-path GlassyHost`: all 144 tests passed.
- `./script/build_and_run.sh --preview`: signed app built and launched successfully.
- General settings displayed **Appearance → Hide Dock icon** with readable explanatory text and the existing startup and update controls.
- Turning the setting on changed the running app's activation policy from regular (`0`) to accessory (`1`); turning it off restored regular activation. Settings remained focused and usable in both directions.
- Restarting the preview with the setting enabled restored accessory activation before opening Settings. The toggle remained on and the rebuilt app displayed version 0.2.13.
- Restored the original visible-Dock preference and stopped the preview after validation. The menu bar Settings action was also reviewed for access while accessory activation hides the application menu.
- Independent code review found no blockers. `git diff --check` passed.

## Published artifacts

- [Public release](https://github.com/Bunn/GlassyDesk-Host/releases/tag/v0.2.13) contains the universal Apple Silicon/Intel app ZIP and drag-to-Applications DMG.
- The release pipeline verified Developer ID signatures, both architectures, Apple notarization, stapled app and installer tickets, Gatekeeper acceptance, and the app mounted from the installer.
- The final ZIP signature verified against the existing Sparkle public key. Published download bytes matched the local artifacts.
- The [production appcast](https://glassydesk-host.pages.dev/glassy-host/appcast.xml) matched the generated feed and expected headers after the direct Cloudflare Pages deployment. Distribution feed commit: `bef535cd4714079fd550c79cc7d1a4d6e3399ead`.
- Local receipts `dist/publish-0.2.13-dcac27e2/state.json` and `dmg/state.json` both record completion. Receipts remain excluded from version control.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `GlassyHost-0.2.13.zip` | 5,884,020 | `0eb73e4eef8bed3aa7574a5719d7c39f8789125429865aaff0552fab933e6550` |
| `GlassyDesk-0.2.13.dmg` | 6,840,098 | `3343d92d8c9354ba8465a4871bbffff5813c796189fd37660174f018c45a1015` |
| `glassy-host/appcast.xml` | — | `b8e58b718a4233606ed7c9cc0d2ef5af883dc3101c9bb25c2f188cff1db6fd55` |

## Sparkle upgrade

The existing Mac 0.2.12 installation discovered 0.2.13 through **Check for Updates…**, displayed the new release notes, downloaded the update, and completed **Install and Relaunch**. A verified backup of the previous app was retained locally before installation.

`/Applications/Glassy Host.app` now reports 0.2.13 (17). Deep signature verification and stapler validation passed; Gatekeeper accepted it as `Notarized Developer ID`. The relaunched app reports **Ready to connect**, retains the three existing iPad approvals, and displays the new setting in General with the original visible-Dock preference.
