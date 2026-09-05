# Release Glassy Desk for Mac

Run the release automation from the `Bunn/glassyview` source repository:

```sh
./script/release_host.sh --notes /path/to/release-notes.md
```

It builds a universal macOS 14+ app, signs it with Developer ID, submits it to Apple for notarization, staples and validates the ticket, and signs the final ZIP with Sparkle. It also creates a branded drag-to-Applications DMG from that same app, signs and notarizes the disk image, and checks both the image and the app inside it. It publishes both files through a GitHub Release in `Bunn/GlassyDesk-Host`, updates that repository's appcast while preserving older entries, and deploys the feed directly to Cloudflare Pages project `glassydesk-host`.

The website uses `GlassyDesk-VERSION.dmg` for first installs. Sparkle keeps using `GlassyHost-VERSION.zip` for automatic updates. The public distribution repository receives the appcast and site headers; both downloads are release assets. The automation does **not** bump source versions or commit or push source changes.

## Prepare a new release

1. Install Xcode and its command-line tools, select the intended Xcode with `xcode-select`, and finish its first-run setup. The project requires Xcode 26 or later. Install Python 3.10+ and Node.js/npm as well. The script uses the committed Swift dependency lockfile and pins Wrangler to `4.128.0`.
2. Increment **both** `CFBundleShortVersionString` and `CFBundleVersion` in [`GlassyHost/Support/Info.plist`](../GlassyHost/Support/Info.plist). Version `0.2.0`, build `4`, is already published; choose a new version and a higher build. Sparkle compares build versions when deciding whether an update is newer.
3. Verify the source changes and run the host tests: `swift test --package-path GlassyHost`.
4. Write the public release notes in a UTF-8 file. Review the source and notes before starting; the command publishes the release without a further interactive approval.

Public destinations and release settings live in [`script/host-release.json`](../script/host-release.json). Its optional `cloudflare_account_id`, or the `CLOUDFLARE_ACCOUNT_ID` environment variable, selects the Cloudflare account. Account IDs and signing identity names are configuration, not secrets. `--config FILE` selects another public configuration file; its bundle, feed, and Sparkle key settings must match the app.

Install the pinned DMG tools once with a Python 3.10+ interpreter:

```sh
python3 -m venv .build/dmgbuild
.build/dmgbuild/bin/python -m pip install -r script/dmg/requirements.txt
```

The release orchestrator itself still supports Python 3.9. Set `GLASSY_DMG_PYTHON` to an absolute interpreter path if the DMG tools are installed elsewhere. The installer artwork is drawn with AppKit by [`render_background.swift`](../script/dmg/render_background.swift), including standard and Retina TIFF representations. Finder presents the real app and Applications shortcut over the artwork. The layout leaves room for Finder's optional path and status bars. No Finder automation or user preference changes are needed.

## Credentials

Local runs accept secret environment variables or credentials saved in the macOS Keychain. Environment values take precedence. CI uses environment secrets only and does not consult the local credential store.

| Purpose | Environment variable | Local credential name |
| --- | --- | --- |
| Distribution repository access | `GH_TOKEN` or `GITHUB_TOKEN` | `github-token` |
| Cloudflare Pages deployment | `CLOUDFLARE_API_TOKEN` | `cloudflare-token` |
| Existing Sparkle private key | `SPARKLE_PRIVATE_KEY` | `sparkle-key` |
| Apple notarization private key, PEM text | `NOTARY_PRIVATE_KEY` | `notary-key` |
| Developer ID certificate and private key, base64 PKCS#12 | `CODESIGN_P12_BASE64` | `codesign-p12` |
| PKCS#12 password; an empty password is allowed | `CODESIGN_P12_PASSWORD` | `codesign-password` |

Use a fine-grained GitHub PAT or GitHub App token with **Contents: write** on `Bunn/GlassyDesk-Host`. The source repository's default Actions token cannot publish to another repository. See [GitHub release permissions](https://docs.github.com/en/rest/releases/releases) and [Actions token scope](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token).

The Cloudflare token needs **Account → Cloudflare Pages → Edit**, scoped to the account hosting `glassydesk-host`. Supply `CLOUDFLARE_ACCOUNT_ID` through local configuration or a CI variable. See [Cloudflare's CI direct-upload guide](https://developers.cloudflare.com/pages/how-to/use-direct-upload-with-continuous-integration/).

For notarization, provide the `.p8` private key plus `NOTARY_KEY_ID`. Team API keys also require `NOTARY_ISSUER_ID`; omit the issuer for individual API keys. Locally, `NOTARY_KEY_PATH` can point to the private PEM file instead of supplying its contents. An existing `NOTARY_KEYCHAIN_PROFILE`, with optional `NOTARY_KEYCHAIN`, is another local option if it is already accessible without an authentication dialog. This `notarytool` path is the default and is required in CI. Apple documents the submission process in [Notarization with notarytool](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool).

On a development Mac that is already signed into the correct Apple developer account in Xcode, a local fallback can use that account without a `.p8` key:

```sh
./script/release_host.sh --notes /path/to/release-notes.md --xcode-notarization
```

This mode creates a private `ExportOptions.plist`, submits the packaged archive with `xcodebuild -exportArchive`, and checks for the notarized app for up to 20 minutes before asking you to resume. It is local-only: the script rejects it whenever `CI` or `GITHUB_ACTIONS` is enabled. The account must already be authenticated in Xcode, and the exact Developer ID certificate used to package the app must remain available. Use an API key for repeatable CI releases.

The same account also notarizes the DMG. Because Xcode uploads app archives, the automation includes the signed disk image as a resource in a private, separately signed copy of the app archive. Apple scans that nested image. The wrapper is never distributed: the release requires a successful `stapler staple` and `stapler validate` on the **DMG itself**, followed by Gatekeeper assessment and validation of its contents. Acceptance of the wrapper alone cannot publish the installer. With `notarytool`, the DMG is submitted directly. No additional Apple credential is required when using the existing signed-in Xcode account.

### Save local credentials once

The importer stores generic-password items under service `dev.bunn.glassydesk.release` in the current user's default macOS Keychain. Omitting `--file` opens a hidden terminal prompt:

```sh
./script/release_host.sh credentials import --name github-token
./script/release_host.sh credentials import --name cloudflare-token
./script/release_host.sh credentials import --name codesign-password
```

For a private file, use `--file`. Files must be owned by the current user, with permissions `600` or `400`. Keep these files outside the repository. A binary `.p12` is automatically converted to base64 by the importer:

```sh
./script/release_host.sh credentials import --name notary-key --file /private/path/AuthKey.p8
./script/release_host.sh credentials import --name codesign-p12 --file /private/path/DeveloperID.p12
```

`--file -` reads from standard input, for example when piping directly from a secret manager. For `codesign-p12`, stdin and hidden terminal entry require base64 text; only `--file PATH` accepts the binary file. Do not put secret values in command arguments or shell history. Re-importing a name updates its saved value. There is no credential-export command.

Use the same trusted Python executable for setup and releases, and unlock the user Keychain before running. Keychain access disables authentication UI; inaccessible items fail with an actionable error. The store trusts the Python executable used during setup, so other scripts running through that executable share its access. Environment credentials are an alternative when local Keychain access is unavailable.

### Export the existing Sparkle key

The deployed app trusts the existing Sparkle public key. **Do not generate a replacement key for this automation.** Export the matching private key once from the existing Sparkle Keychain account `dev.bunn.glassydesk.host`, then import that export into the release credential store:

```sh
umask 077
GlassyHost/.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account dev.bunn.glassydesk.host -x /private/path/glassy-host-sparkle.key
./script/release_host.sh credentials import --name sparkle-key \
  --file /private/path/glassy-host-sparkle.key
```

The destination must be a new file in a private directory that already exists. The Sparkle tool is available after the locked package dependencies have been resolved. Original-key access during this one-time export may require Keychain authorization. Keep a secure backup and remove any temporary export after setup; never commit it. For CI, save the exported base64 text as `SPARKLE_PRIVATE_KEY`. The release script accepts the current 32-byte and legacy 96-byte private-key formats. See [Sparkle's key export documentation](https://sparkle-project.org/documentation/).

The final ZIP must stay byte-for-byte identical after its Sparkle signature is generated. The automation signs after notarization and stapling, then publishes that exact archive.

### Developer ID signing

Local releases may use an installed **Developer ID Application** identity. Select an exact certificate SHA-1 or full identity name with `--identity`, or set `GLASSY_HOST_CODESIGN_IDENTITY`. A development or ad-hoc identity cannot produce this release.

For unattended signing, export the Developer ID Application certificate **with its private key** as a password-protected `.p12`. Import it and its password with the local credential commands, or supply `CODESIGN_P12_BASE64` and `CODESIGN_P12_PASSWORD` in the environment. CI requires the PKCS#12 secret, even if a runner has an existing signing identity.

The script imports the PKCS#12 through the native Security framework into a temporary keychain. Its password is never passed as a process argument. Only the temporary keychain's random, short-lived password is used in keychain-management command arguments. The script does not change the default keychain or its search list, and removes the temporary signing keychain when the run ends.

## Run and recover

Review a dry run, then start the release with the same inputs:

```sh
./script/release_host.sh --notes /path/to/release-notes.md --dry-run
./script/release_host.sh --notes /path/to/release-notes.md
```

`--dry-run` reads only local configuration, version information, and notes or saved state. It does not read credentials, create a workspace, build, contact remote services, or check whether the version is already published. A new dry run still requires `--notes`.

To choose the signing identity and workspace explicitly:

```sh
./script/release_host.sh --notes /path/to/release-notes.md \
  --identity "Developer ID Application: Your Name (TEAMID)" \
  --work-dir /path/to/new-release-workspace
```

`--work-dir` must name a new directory; the default is a unique `dist/publish-VERSION-ID` directory. The command prints its workspace and a resume command at the start, then records progress in `state.json`. Keep the workspace and the packaging output until the release has completed. The automation uses [`package_host_release.sh`](../script/package_host_release.sh) to build and sign, then handles notarization, verification, Sparkle signing, the GitHub draft and asset, appcast publication, and the direct Cloudflare deployment. A Git push alone does not deploy this Pages project.

If a run stops after packaging completed, correct the reported problem and resume from the existing workspace:

```sh
./script/release_host.sh --resume /path/to/existing-release-workspace
```

Resume uses the saved release state and the same artifact; it never recompiles. Keep the workspace contents, the packaged `.xcarchive`, and the release configuration intact, and make the credentials needed for the remaining stages available again. The receipt remembers whether the run uses `notarytool` or the signed-in Xcode account, so resume without repeating `--xcode-notarization`. Do not combine `--resume` with `--notes`, `--identity`, `--work-dir`, or `--xcode-notarization`.

If credentials, preflight, or compilation failed before a completed packaging receipt (`package.json`) was created, resume refuses to continue. Correct the problem and start a new run with `--notes` and a new workspace. Once an artifact is published, use resume to finish that release; do not replace its signed asset or start a separate release under the same version. Subsequent source changes require a new version and build.

The published feed is [Glassy Desk for Mac's appcast](https://glassydesk-host.pages.dev/glassy-host/appcast.xml); binaries are in [GitHub Releases](https://github.com/Bunn/GlassyDesk-Host/releases). The script preserves existing feed entries when adding the new release.

### Add the installer to an already published release

For an older release that shipped only a ZIP, use its completed local receipt:

```sh
./script/release_host.sh --add-dmg /path/to/existing-release-workspace --dry-run
./script/release_host.sh --add-dmg /path/to/existing-release-workspace
```

This verifies and extracts the original ZIP, adds a signed and notarized DMG to the same owned GitHub release, and verifies the public download. It leaves the original release receipt, app version, ZIP, Sparkle signature, and appcast intact. It needs GitHub access and the existing signing/notarization setup; it does not need Cloudflare or the Sparkle private key. The notarization mode comes from the original receipt.

Progress lives in `dmg/state.json` inside the original release workspace. Repeat the same `--add-dmg` command to resume. The signed submission is kept separately from the stapled download so interrupted stapling can be retried. After the final DMG digest is recorded, changed or missing bytes are rejected. An existing remote asset is reused only when its bytes match; it is never overwritten. New releases create both downloads automatically, while resuming an older receipt preserves its original release plan.

## Optional manual GitHub Actions workflow

The following is a template only; this document does not enable a workflow. Add it to the `Bunn/glassyview` source repository if desired, after configuring the secrets and variables. Use a macOS runner with the required Xcode selected. The notes path must point to a reviewed file in the checked-out revision.

```yaml
name: Release Glassy Desk for Mac

on:
  workflow_dispatch:
    inputs:
      notes_path:
        description: Path to the reviewed release notes in this revision
        required: true
        type: string

permissions:
  contents: read

concurrency:
  group: glassy-host-release
  cancel-in-progress: false

jobs:
  release:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
      - name: Install DMG packaging tools with Python 3.10+
        run: |
          python3 -m venv .build/dmgbuild
          .build/dmgbuild/bin/python -m pip install -r script/dmg/requirements.txt
      - name: Build, notarize, and publish
        env:
          CI: 'true'
          NOTES_FILE: ${{ inputs.notes_path }}
          GH_TOKEN: ${{ secrets.HOST_RELEASE_GITHUB_TOKEN }}
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          CLOUDFLARE_ACCOUNT_ID: ${{ vars.CLOUDFLARE_ACCOUNT_ID }}
          SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}
          NOTARY_PRIVATE_KEY: ${{ secrets.NOTARY_PRIVATE_KEY }}
          NOTARY_KEY_ID: ${{ vars.NOTARY_KEY_ID }}
          NOTARY_ISSUER_ID: ${{ vars.NOTARY_ISSUER_ID }}
          CODESIGN_P12_BASE64: ${{ secrets.CODESIGN_P12_BASE64 }}
          CODESIGN_P12_PASSWORD: ${{ secrets.CODESIGN_P12_PASSWORD }}
          GLASSY_HOST_CODESIGN_IDENTITY: ${{ vars.GLASSY_HOST_CODESIGN_IDENTITY }}
        run: >-
          ./script/release_host.sh --notes "$NOTES_FILE"
          --work-dir "$RUNNER_TEMP/glassy-host-release"
```

`HOST_RELEASE_GITHUB_TOKEN` is the separate distribution-repository token, not the workflow's default `GITHUB_TOKEN`. Store the notarization `.p8` as multiline PEM text, the existing Sparkle export as base64 text, and the `.p12` as base64 text. Set `NOTARY_ISSUER_ID` only for a team API key. The signing identity and API key IDs can be repository variables; the private keys, tokens, and PKCS#12 password must be secrets.

A hosted runner is disposable. `--resume` needs its existing workspace and artifact, so a later job cannot resume an earlier job after those files have been discarded. Do not upload private key exports or credential files as workflow artifacts.
