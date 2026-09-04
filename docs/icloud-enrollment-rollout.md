# iCloud enrollment rollout

The iCloud enrollment implementation is complete on the `icloud` branch and is intentionally not enabled on `main`. Do not publish iOS or macOS builds from this branch until the production CloudKit container and the Developer ID provisioning profile are ready.

## What is implemented

- Saved Macs, connection routes, user preferences, and encrypted passwords continue to sync through the private CloudKit container `iCloud.dev.bunn.dejaview`.
- Every iOS installation owns a device-local X25519 identity. The private key never enters iCloud.
- A signed-in iOS device can request a short-lived, one-time enrollment grant from a Glassy Host signed into the same Apple Account.
- The host seals each grant specifically for the requesting device with X25519 key agreement and AES-GCM encryption.
- The host exchanges the grant for the normal per-device resume secret, so an iPhone and iPad can connect at the same time without sharing a client identity.
- QR code, password, LAN, Tailscale, and WireGuard connection paths remain available as fallbacks.
- The host enables automatic iCloud enrollment only when its bundle contains a matching CloudKit-enabled provisioning profile.
- The macOS release script validates the Production CloudKit schema, embedded profile, signing certificate, and final signed entitlements before it publishes anything.

## Apple Developer setup

1. In Certificates, Identifiers & Profiles, open the explicit App ID `dev.bunn.glassydesk.host` for team `B2RUA6XMHC`.
2. Enable iCloud with CloudKit and attach the existing container `iCloud.dev.bunn.dejaview`.
3. Create a Developer ID provisioning profile for that App ID. Select the installed `Developer ID Application: Fernando Bunn (B2RUA6XMHC)` certificate.
4. Download the profile and save it outside this repository with permissions `600` or `400`.
5. Import it into the release credential store:

   ```sh
   chmod 600 /private/path/GlassyHost.provisionprofile
   ./script/release_host.sh credentials import \
     --name cloudkit-profile \
     --file /private/path/GlassyHost.provisionprofile
   ```

The profile must authorize `iCloud.dev.bunn.dejaview` and the Production CloudKit environment. Local unsigned or development builds keep automatic iCloud enrollment disabled.

## CloudKit schema

Create the `GlassyHostEnrollmentRequestV1` record type in the development schema of `iCloud.dev.bunn.dejaview` with these fields:

```text
version INT64
hostIdentifier BYTES
clientIdentifier BYTES
deviceName STRING
clientPublicKey BYTES
requestNonce BYTES
requestedAt TIMESTAMP
requestExpiresAt TIMESTAMP
fulfilledNonce BYTES
hostEphemeralPublicKey BYTES
sealedGrant ENCRYPTED BYTES
grantExpiresAt TIMESTAMP
```

No query indexes are required. Confirm that `sealedGrant` is an encrypted Bytes field before production deployment; a production field cannot be converted to encrypted storage later.

Deploy the schema changes to Production in CloudKit Console. The apps automatically create each Apple Account's private `GlassyEnrollmentV1` zone at runtime.

## Save schema verification credentials

Create a CloudKit management token and save it in the macOS Keychain once:

```sh
xcrun cktool save-token --type management --method keychain
./script/release_host.sh credentials import --name cloudkit-management-token
```

The second command opens a hidden terminal prompt. Paste the token there. The release tooling passes the token to `cktool` only through the environment and does not include it in process arguments, logs, or release state.

CI should provide the equivalent secrets as `CLOUDKIT_PROVISIONING_PROFILE_BASE64` and `CLOUDKIT_MANAGEMENT_TOKEN`.

## Verify Production before a release

Export and validate the Production schema independently:

```sh
xcrun cktool export-schema \
  --team-id B2RUA6XMHC \
  --container-id iCloud.dev.bunn.dejaview \
  --environment production \
  --output-file /tmp/glassy-production.ckdb

PYTHONPATH=script python3 -c \
  'from pathlib import Path; from release_host import validate_cloudkit_enrollment_schema; validate_cloudkit_enrollment_schema(Path("/tmp/glassy-production.ckdb").read_bytes()); print("Production CloudKit schema: OK")'
```

Build and verify a local host with the saved Production profile:

```sh
./script/build_and_run.sh --verify
```

Confirm that the resulting host bundle contains `Contents/embedded.provisionprofile` and that iCloud enrollment starts without entitlement or CloudKit environment errors.

## End-to-end validation

Use a new iOS build from the `icloud` branch and a Developer ID host built from the same branch. Test these cases before release:

- iPhone, iPad, and Mac use the same Apple Account and automatic enrollment succeeds without entering a password.
- The iPhone and iPad remain connected at the same time and receive different per-device credentials.
- Connections work over the same LAN, Tailscale, and WireGuard, including scanning a QR code while outside the host's physical network.
- A device using another Apple Account, with iCloud disabled, or with CloudKit temporarily unavailable can still use QR code or password pairing.
- Revoking one device blocks that device without breaking another enrolled device.
- Expired or replayed enrollment grants are rejected.
- Existing saved hosts and encrypted credentials migrate without data loss or a launch crash.

## Release checklist

1. Merge or otherwise promote the reviewed `icloud` branch only after Production schema validation and the end-to-end tests pass.
2. Increase the iOS build number as required for TestFlight. The branch currently uses marketing version `1.3`, build `3`.
3. Increase both `CFBundleShortVersionString` and `CFBundleVersion` for Glassy Host beyond the latest published Sparkle release.
4. Publish and test the iOS TestFlight build.
5. Run a real TestFlight-to-Developer-ID-host enrollment test using Production CloudKit.
6. Run the Sparkle release script. Its Production schema and profile checks fail before compilation or publication when setup is incomplete:

   ```sh
   ./script/release_host.sh --notes /private/path/release-notes.md
   ```

## Validation already completed

The implementation at commit `0395efb` passed:

- the full iOS test suite;
- 98 Glassy Host tests;
- a real host enrollment loopback test;
- 80 Python release automation tests;
- a universal `arm64` and `x86_64` release build;
- shell syntax, entitlement, dry-run, and whitespace checks.

The Production CloudKit export, notarization, TestFlight distribution, and live cross-device Production test remain pending because this Mac does not yet have the required CloudKit management token and Developer ID provisioning profile.
