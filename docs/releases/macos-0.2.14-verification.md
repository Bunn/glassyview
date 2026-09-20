# Mac 0.2.14 (18) release verification

Published September 20, 2026 from source commit `56da281be62a62dec718292f17c6abe3ec66b1fd`.

## Build and release checks

- `swift test --package-path GlassyHost`: all 152 tests passed.
- `python3 -m unittest discover -s script/tests`: all 89 tests passed, including architecture checks that reject missing Intel or Apple Silicon slices.
- Xcode 27 built the universal Release app. Its `lipo -verify_arch` command rejected valid universal binaries, so packaging now reads `lipo -archs` and explicitly requires both `arm64` and `x86_64`.
- `bash -n script/package_host_release.sh` and `git diff --check` passed.
- Both the app and DMG passed Developer ID signature verification, notarization, ticket stapling, and Gatekeeper assessment. The installer contains the app extracted from the immutable Sparkle ZIP; its mounted app passed the same checks.
- App notarization submission: `167efab6-9409-4ce4-a865-0744899f0bea`. DMG submission: `3f5f887c-ae52-4d97-bce3-9dda30254e7e`. Both were accepted.

## Signing recovery and trust continuity

The previous Developer ID and Sparkle private keys were unavailable. The new Developer ID Application certificate belongs to the existing team `B2RUA6XMHC`, has SHA-1 `6B0F5C09E54FB305E358F5F0ED252800D05DF62C`, and expires September 17, 2031. The new Sparkle public key is `4Rre8LBS6LmX3rAR/I8srcEJbkEQJTnxZ96v6WuFifI=`. Private keys and credential backups remain outside the repository.

The unmodified public 0.2.13 (17) app ships Sparkle 2.9.6 and does not enable `SUVerifyUpdateBeforeExtraction` or `SURequireSignedFeed`. The new app satisfies that old app's designated requirement on both architectures, preserving the Apple team and bundle identity while changing certificates.

A standalone harness compiled Sparkle 2.9.6's actual validation sources at `ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a` and exercised its post-extraction trust check with the final ZIP and the installed 0.2.13 app. Only Objective-C direct-dispatch attributes were disabled to expose the private validation method; installer discovery aborted if called. No validation logic was replaced.

| Case | Old Ed25519 key | New Ed25519 key | Old code requirement | Sparkle result |
| --- | --- | --- | --- | --- |
| Final release | Fails, as expected after rotation | Passes | Passes | Accepted |
| Corrupted archive signature | Fails | Fails | Passes | Rejected |
| App copy re-signed ad hoc | Fails | Passes | Fails | Rejected |

The harness source, compiler arguments, and results are retained in the local release workspace's `rotation-validation` directory. The [migration guide](../macos-release-migration.md#certificate-renewal-or-lost-keys) records the recovery rules and current public identity.

## Published artifacts

- [Public release](https://github.com/Bunn/GlassyDesk-Host/releases/tag/v0.2.14) contains the universal app ZIP and drag-to-Applications DMG. The publishing pipeline downloaded both assets and verified their bytes against the local hashes.
- The [production appcast](https://glassydesk-host.pages.dev/glassy-host/appcast.xml) matched the generated feed and expected cache/content-type headers after Cloudflare Pages deployment. Older feed entries were preserved. Distribution feed commit: `9e2ad50bdb9088153f74702223e658a6d2ccd769`.
- Local receipts `dist/publish-0.2.14-key-recovery/state.json` and `dmg/state.json` both record completion and remain excluded from version control.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `GlassyHost-0.2.14.zip` | 6,263,782 | `7bdb374778029d80b4436dba5f6c8709c85efec9927e0b4903d3daa513c93b2a` |
| `GlassyDesk-0.2.14.dmg` | 7,226,118 | `fe1f23f04f5f78e4687423b7fb2bf7c63c68cd5f3d6187cb34e7c470c890d0af` |
| `glassy-host/appcast.xml` | — | `15a7ebb05144ea4a5206b3230c89e68e88fa9e6f4792c3d3a1add82dd070348b` |

## Existing-user Sparkle upgrade

The installed `/Applications/Glassy Desk.app` at 0.2.13 discovered 0.2.14 through **Check for Updates…**, displayed the release notes, downloaded and validated the update, and completed **Install and Relaunch**. A verified backup of 0.2.13 was retained in the local release workspace before installation.

The installed app now reports 0.2.14 (18) and the new Sparkle public key. Deep signature verification across architectures and stapler validation passed; Gatekeeper accepted it as `Notarized Developer ID`.

After relaunch, the app reported **Ready to connect**, retained its existing paired device and enabled connection setting, and showed Screen Recording, Accessibility, and Direct Screen Access as allowed. The General settings retained their previous startup and Dock-icon values. A second update check reported **You're up to date** for 0.2.14.

No physical iPhone or iPad was connected during this release check, so a live remote-control session and sleep/wake reconnection were not retested on hardware here.
