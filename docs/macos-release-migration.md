# Move Mac releases to another computer

Move the release tools and credentials while keeping Glassy Desk's existing signing identity, Sparkle key, and update URLs. An existing installation should receive the next release through **Check for Updates…**, keep its paired devices and settings, and continue to be recognized as the same app by macOS.

This is the companion to [the release runbook](macos-release.md). The commands below run from the `Bunn/glassyview` repository root. Replace `/private/path/...` placeholders with your own private locations. This document contains public identifiers only; writing it did not export or back up any private keys.

## What signs what

| Layer | Signer or credential | What the current pipeline does |
| --- | --- | --- |
| App and embedded Sparkle code | Our **Developer ID Application certificate and its private key** | Signs nested Sparkle helpers, the framework, and then `Glassy Desk.app`, with hardened runtime and secure timestamps. |
| macOS notarization | Apple, after an authenticated submission | Issues tickets for the app and DMG. The script staples and validates them and checks Gatekeeper acceptance. An Xcode login authorizes submission; it does not replace our signing private key. |
| Sparkle update ZIP | Our separate **Sparkle Ed25519 private key** | Signs the final ZIP after app notarization and stapling. The script verifies that signature against the public key already embedded in released apps. |
| First-install DMG | Our Developer ID Application identity, plus Apple's notarization ticket | Builds the welcome window around the exact app extracted from the final ZIP, signs and notarizes the image, and verifies the app inside it. The DMG is the website download. |
| Publishing | GitHub and Cloudflare credentials | Uploads immutable release assets and deploys the existing HTTPS appcast. These credentials do not sign code or updates. |

The source implementation is [package_host_release.sh](../script/package_host_release.sh), [release_host.py](../script/release_host.py), and [host_release_dmg.py](../script/host_release_dmg.py). The feed currently carries an Ed25519 signature for the ZIP; the XML feed itself is not separately signed. There is no `.pkg` installer, so this workflow does not need a **Developer ID Installer** certificate. Apple distinguishes application and package signing in its [Developer ID guide](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

The person operating the new Mac can change. The app must still be signed using the authorized Glassy Desk Developer ID identity, not that person's unrelated development team. Customers do not install our certificate or change their updater settings when the build computer changes.

## Public identity to preserve

These values were checked against version **0.2.7 (11)** and the release scripts on **2026-09-05**. For later migrations, recheck [host-release.json](../script/host-release.json), [the host Info.plist](../GlassyHost/Support/Info.plist), and the most recent shipped app before relying on this snapshot.

| Item | Current value |
| --- | --- |
| Developer ID Application identity | `Developer ID Application: Fernando Bunn (B2RUA6XMHC)` |
| Apple Developer Team ID | `B2RUA6XMHC` |
| Current signing certificate SHA-1, for exact selection | `C4BF2CFE6BEDB7CBD8656F332685D0AE3B4FB6B3` |
| Current certificate expiry | **2027-02-01 at 22:12:15 UTC**; inspect again before migration or renewal |
| Bundle and code-signing identifier | `dev.bunn.glassydesk.host` |
| App bundle / executable | `Glassy Desk.app` / `GlassyHost` |
| Sparkle public key (`SUPublicEDKey`) | `ipAMEzRnoCI5mU96B1X14pX/XJJFShB7NlVpJwIG+Yg=` |
| Sparkle tools' Keychain account | `dev.bunn.glassydesk.host` |
| Release credential Keychain service | `dev.bunn.glassydesk.release` |
| Sparkle feed (`SUFeedURL`) | `https://glassydesk-host.pages.dev/glassy-host/appcast.xml` |
| Distribution repository / branch | `Bunn/GlassyDesk-Host` / `main` |
| Cloudflare account / Pages project | `6e73c78f9eaeeaa3298c750113cf498e` / `glassydesk-host` |
| Public Mac download and setup page | `https://bunn.dev/glassydesk/mac/` |
| Website repository / publishing branch | `Bunn/bunn.github.io` / `master` |

For a normal computer move, preserve the same certificate **and private key**, the same Sparkle key, and all app identifiers. The published app's designated requirement identifies this bundle and Apple team; it is not tied to the build Mac's username or hardware. That requirement is relevant to macOS recognizing updates and retaining access to protected resources. See Apple's [code identity explanation](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

The release script uses [GlassyHost.entitlements](../GlassyHost/Support/GlassyHost.entitlements), currently an empty entitlement dictionary, and enables hardened runtime through signing options. It does not use the ad-hoc development entitlement that disables library validation. Do not substitute `build_and_run.sh` for the release command: local development builds can have a different signing identity and storage behavior.

## Before retiring the old Mac

Finish any in-progress release first. Keep the old Mac available until a release made on the replacement computer has passed the upgrade checks below.

### 1. Back up the Developer ID identity

In **Keychain Access → login → My Certificates**, locate the Developer ID Application identity above. Expand it and confirm that its **private key** is present. Select the identity, choose **File → Export Items**, and export a password-protected `.p12`. Keep the export and its password in your secure backup or password manager, outside the repositories. A downloaded `.cer` contains the certificate but cannot replace the missing private key. Apple's [Keychain export/import instructions](https://support.apple.com/guide/keychain-access/import-and-export-keychain-items-kyca35961/mac) describe this transfer.

Record the identity's public fingerprint and expiry alongside the backup. These commands do not export the private key:

```sh
security find-identity -v -p codesigning
security find-certificate \
  -c 'Developer ID Application: Fernando Bunn (B2RUA6XMHC)' -p \
  | openssl x509 -noout -subject -issuer -dates -fingerprint -sha1
```

If several certificates have the same name, use Keychain Access to identify the exact certificate used by the release, and select it by SHA-1 with `--identity` when releasing. Do not revoke the old certificate just to move computers.

### 2. Back up the existing Sparkle key

The original Sparkle tools' Keychain entry and our release credential store are two separate entries. The automation reads `sparkle-key` from the release store (or `SPARKLE_PRIVATE_KEY`); it does not automatically read Sparkle's original entry.

On the old Mac, export the existing key from Sparkle's account to a **new file** in a private backup directory:

```sh
umask 077
GlassyHost/.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account dev.bunn.glassydesk.host -p
GlassyHost/.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account dev.bunn.glassydesk.host -x /private/path/glassy-host-sparkle.key
```

Check that the printed public key matches `SUPublicEDKey` above. Keep the exported private key in an encrypted backup. `generate_keys -x` and `-f` are the supported transfer operations; do not generate a new key on the replacement computer. See [Sparkle's key transfer and rotation guidance](https://sparkle-project.org/documentation/#eddsa-ed25519-signatures).

If only the release store retains the key, recover its existing `sparkle-key` value through your secure credential backup or Keychain access, without printing it in logs. The release CLI intentionally has no credential-export command. Do not substitute a newly generated key because a backup is missing.

### 3. Preserve account access and release records

| Item | What to preserve or restore |
| --- | --- |
| Apple Developer membership | Access to team `B2RUA6XMHC`, account recovery, and the ability to authenticate Xcode. The current local route uses the signed-in Xcode account; it does not require an existing `.p8` file. |
| Optional `notarytool` setup | If using it, preserve the `.p8`, key ID, and team issuer ID, or recreate the Keychain profile with authorized credentials. A profile name alone is not a credential backup. |
| GitHub | Access to the source repo and **Contents: write** on the distribution repo. Preserve or replace the publishing token. Source Git SSH access and the release HTTP API token are separate. |
| Cloudflare | Access to the existing account and Pages project, plus a token with **Account → Cloudflare Pages → Edit** scoped to that account. |
| Release artifacts | Final ZIPs, DMGs, receipts, packaging manifests, original `.xcarchive` directories, notarization records, and available debug symbols. Keep the last known-good public app for upgrade testing. |
| Source and configuration | Push the intended source commit and keep the committed `GlassyHost/Package.resolved`, release scripts, public configuration, and DMG requirements. |

Tokens and account sessions can be replaced with equivalent access without changing customer trust. Signing keys require more care. Store the actual credential backups separately from this guide; neither Git nor a fresh Xcode sign-in restores all private keys.

The release store's credential names, accepted formats, and hidden-input commands are listed in [Credentials](macos-release.md#credentials). Keep backup files owner-readable only (`chmod 600`) when importing them. Do not put private key contents, passwords, or tokens into shell arguments, source files, release notes, or GitHub assets.

## Set up the replacement Mac

### 1. Restore the tools and repositories

Clone `Bunn/glassyview` and check out the intended release commit. Install full Xcode with a Swift toolchain compatible with [Package.swift](../GlassyHost/Package.swift), currently Swift tools **6.2** or later. Version 0.2.7 was released using Xcode **26.6**. Select Xcode in its settings or with `xcode-select`, and finish its first-run setup. Install Python **3.10+**, Node.js/npm, and Git. The orchestrator supports Python 3.9, but `dmgbuild` requires 3.10+.

```sh
xcode-select -p
xcodebuild -version
swift --version
python3 --version
node --version
npm --version
swift package --package-path GlassyHost --force-resolved-versions resolve
python3 -m venv .build/dmgbuild
.build/dmgbuild/bin/python -m pip install -r script/dmg/requirements.txt
```

Recreate the virtual environment on the new machine; do not copy its old interpreter paths. Use `GLASSY_DMG_PYTHON` if the DMG environment is elsewhere. Check `git diff -- GlassyHost/Package.resolved` stays empty. Clone the website repo only if also maintaining its download/setup page; it is not required for routine Sparkle feed deployment.

### 2. Restore signing and Xcode notarization

Import the saved `.p12` into the new Mac's **login Keychain** through Keychain Access, entering its password locally. Verify that My Certificates shows the same Developer ID Application certificate **with its private key**, and rerun `security find-identity -v -p codesigning`. Xcode downloading certificates alone is insufficient if the private key was not restored.

Sign in to the authorized Apple developer account in **Xcode → Settings → Accounts** and confirm team `B2RUA6XMHC` is available. Use `--xcode-notarization` for this local workflow. Keep `CI` and `GITHUB_ACTIONS` unset for local releases; that mode intentionally rejects CI.

The app is submitted using `xcodebuild -exportArchive` and retrieved with `-exportNotarizedApp`. For the DMG, the script submits a private app archive containing the signed image as a resource. Only the DMG is distributed, and its **own** ticket and Gatekeeper check must pass. This route was verified for both artifacts in 0.2.7; no additional Apple credential was needed for the DMG.

For CI or a deliberate move to `notarytool`, use the [API-key setup](macos-release.md#credentials) instead. Changing submission credentials within the authorized team does not replace the app's Developer ID signing identity or Sparkle key. Cloud-managed signing alone is not a substitute for the locally usable identity required by our packaging script.

### 3. Restore Sparkle and publishing credentials

Restore the same Sparkle backup into its original tools account, then check the public key:

```sh
GlassyHost/.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account dev.bunn.glassydesk.host -f /private/path/glassy-host-sparkle.key
GlassyHost/.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account dev.bunn.glassydesk.host -p
```

Stop if that public key differs from the committed `SUPublicEDKey`. If this account already contains another key, resolve that conflict without deleting the only copy of either key. Once the restored key matches, import the **same file** into the release automation's store:

```sh
./script/release_host.sh credentials import --name sparkle-key \
  --file /private/path/glassy-host-sparkle.key
./script/release_host.sh credentials import --name github-token
./script/release_host.sh credentials import --name cloudflare-token
```

The last two commands prompt with hidden input. Use the same trusted `python3` executable for credential import and release runs. The importer stores items under `dev.bunn.glassydesk.release` with a restricted Keychain access policy; moving an old Keychain or changing Python paths can require re-importing those entries on the replacement machine. Unlock the login Keychain before release work.

An installed Developer ID identity is sufficient for the local Xcode route. If choosing the automation's PKCS#12 path, also import `codesign-p12` from the binary `.p12` and `codesign-password` using the commands in the release runbook. This path is required in CI. A stale saved `codesign-p12` or environment override takes precedence over the installed identity, so inspect your intended credential setup if the wrong certificate is selected.

The release command does **not** automatically use `gh auth login`, `wrangler login`, or `asc auth login` credentials. Configure its own environment variables or release Keychain entries. Some releases on the original Mac used a Wrangler OAuth token supplied to the process; that temporary session is not portable. On the replacement machine, configure a scoped Cloudflare API token with sufficient lifetime for compilation, both notarizations, and deployment. Existing sessions or tokens must be refreshed through their provider when expired; do not copy an expired OAuth value into the release store.

## Prove continuity before retiring the old setup

1. **Check identity.** Compare the restored certificate fingerprint, Team ID, Sparkle public key, bundle ID, and feed URL with the snapshot and the most recent public release. Keep the current release entitlements and credential namespaces.
2. **Check tools without publishing.** Run `python3 -m unittest discover -s script/tests` and `swift test --package-path GlassyHost`. For a real signing rehearsal, run `./script/package_host_release.sh 'Developer ID Application: Fernando Bunn (B2RUA6XMHC)'`. It creates a new archive without installing, notarizing, or publishing it. Compare its signature and designated requirement with the last shipped app using the commands below. This packaging ZIP is not a finished release download.
3. **Review the next release.** Bump both host version and build beyond the current production feed, not merely beyond the snapshot in this document. Write release notes, then run the local dry run below. Dry run does not check credentials, Apple, GitHub, or Cloudflare.
4. **Publish and verify the first release from the replacement Mac.** The real release command validates the app, verifies the ZIP's Sparkle signature against the unchanged public key, notarizes and checks the DMG, verifies uploaded bytes, and confirms the production feed. Inspect the completed receipt and public downloads.
5. **Exercise an existing installation.** On a separate test Mac, keep an unmodified older public release installed in `/Applications`, with its permissions granted, a paired iPhone/iPad, and saved settings. Choose **Check for Updates…** to update to the release made on the new computer. Confirm the updated app launches normally, a paired device reconnects without re-pairing, saved settings persist, permission status refreshes, and another update check works. Test the DMG on a clean installation too. Keep the old release machine until these checks pass.

Use paths to the actual extracted or packaged app bundles for these read-only checks:

```sh
codesign -d --verbose=4 -r- '/path/to/previous/Glassy Desk.app'
codesign -d --verbose=4 -r- '/path/to/new/Glassy Desk.app'
codesign --verify --deep --strict '/path/to/new/Glassy Desk.app'
codesign -d --entitlements :- '/path/to/new/Glassy Desk.app'
```

For a normal machine move, the designated requirements should match; compare the team, bundle identifier, Developer ID authority, runtime flag, and timestamp as well. New executable hashes naturally differ. A different designated requirement needs investigation before treating the migration as transparent.

The production host keeps its pairing key in Keychain service `dev.bunn.glassydesk.host.pairing`, account `primary-host-key`; its password credential uses `dev.bunn.glassydesk.host.pairing-password.v1`. The release packager sets `GlassyHostPairingSecretStorage=keychain`. Preserve these namespaces and behavior. Customer pairing secrets and preferences remain on customer devices; they are not release credentials and must not be copied into an app bundle.

Stable signing is necessary for continuity, but it cannot suppress macOS's own future permission or security prompts. Record any repeat permission request during the upgrade check and distinguish a signing regression from the screen-access confirmations that macOS can independently require.

## First release and recovery commands

The following real release command publishes to production. Use the dry run first with reviewed notes and incremented host version/build:

```sh
./script/release_host.sh --notes /private/path/release-notes.md \
  --xcode-notarization --dry-run
./script/release_host.sh --notes /private/path/release-notes.md \
  --xcode-notarization
```

Source commits and pushes are separate from the release command. Sparkle reads the Cloudflare appcast and downloads `GlassyHost-VERSION.zip` from the existing distribution repo; the website selects `GlassyDesk-VERSION.dmg`. Preserve the Pages project and both public URLs. The script updates the distribution Git repository **and** directly deploys the feed to Pages. Pushing Git alone does not deploy the Sparkle feed.

If a release stops after packaging, use its printed workspace:

```sh
./script/release_host.sh --resume /path/to/existing-release-workspace
```

Do not repeat `--xcode-notarization` on resume; the receipt remembers the mode. Refresh only the credentials needed for the remaining work. Do not rebuild or replace a published asset under an existing version/tag. The [runbook](macos-release.md#run-and-recover) covers failures before packaging and the separate `--add-dmg` command for a previously published ZIP-only release.

**In-progress receipts are not automatically relocatable.** `state.json`, `package.json`, and the DMG receipt contain absolute paths to archives or Sparkle tools. Copying only the Git repository or a ZIP is not enough to resume an unfinished release on a different Mac. Finish the run before moving whenever possible. If the move cannot wait, preserve the full workspace, referenced archives and tools, original absolute paths, receipts, and exact artifact bytes; resolve any path recovery deliberately before resuming. New releases can use any checkout path once the old run is complete.

## Certificate renewal or lost keys

Moving a computer does not require a new certificate. The currently recorded certificate expires on **2027-02-01**, so a later migration may also require a planned renewal. Apple explains that already distributed apps can remain usable after certificate expiry, while new releases need a valid signing certificate. Expiry and revocation are different; do not revoke a working identity as a migration step. See [Developer ID certificate expiration](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/#manage-developer-id-certificate-and-provisioning-profile-expiration).

If renewal is necessary, use an authorized Developer ID Application certificate in the **same team**, keep the existing Sparkle key, record the new fingerprint/expiry, and repeat the real old-to-new upgrade check. Update the selected signing identity where necessary; do not change the bundle ID or Sparkle public key to make a signing error go away.

Sparkle supports deliberate rotation of one trust mechanism while the other remains trusted. Do not replace both the Developer ID identity and Sparkle key in the same transition. Loss of the Sparkle key requires a separate recovery/rotation plan, not routine new-Mac setup. Consult [Sparkle's rotation rules](https://sparkle-project.org/documentation/#rotating-signing-keys) against the versions and settings already shipped; pre-extraction verification settings affect available recovery paths. Our normal script pins one public key and is not an automatic key-rotation tool.

Keep the original encrypted backups until the replacement setup has passed the full upgrade check, then maintain recoverable backups of the signing identity, Sparkle key, and release records independently of either computer.
