"""Release safety regressions using synthetic bytes and mocked external systems only."""

import argparse
import base64
from contextlib import ExitStack, contextmanager, redirect_stderr, redirect_stdout
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_host as release


PAYLOAD = b"synthetic-stapled-zip-contents"
PRIVATE_KEY = base64.b64encode(bytes(range(32))).decode()
SIGNATURE = base64.b64encode(b"s" * 64).decode()
CONFIG = {
    "repository": "Synthetic/Distribution", "branch": "main",
    "feed_path": "glassy-host/appcast.xml", "pages_project": "synthetic-host",
    "feed_url": "https://synthetic-host.pages.dev/glassy-host/appcast.xml",
    "wrangler_version": "4.128.0", "team_id": "SYNTHETIC1",
    "bundle_id": "test.synthetic.host", "sparkle_public_key": base64.b64encode(b"p" * 32).decode(),
    "identity": "Developer ID Application: Synthetic (SYNTHETIC1)",
    "cloudflare_account_id": "a" * 32,
}


def make_state():
    return {
        "schema": 1, "config": copy.deepcopy(CONFIG), "id": "synthetic-run-id",
        "version": "0.3.0", "build": "5", "minimum_system": "14.0",
        "notes": "Connect across networks.\nImprove pairing & device controls.",
        "pub_date": "Thu, 03 Sep 2026 12:00:00 +0000", "tag": "v0.3.0",
        "release_url": "https://github.com/Synthetic/Distribution/releases/tag/v0.3.0",
        "download_url": "https://github.com/Synthetic/Distribution/releases/download/v0.3.0/GlassyHost-0.3.0.zip",
        "identity": CONFIG["identity"], "distribution_base": "b" * 40,
        "signature": SIGNATURE, "length": len(PAYLOAD),
        "sha256": hashlib.sha256(PAYLOAD).hexdigest(), "sparkle_tools": "/synthetic/sparkle/bin",
    }


def historical_feed():
    return f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{release.SPARKLE}">
<channel><title>Synthetic Host updates</title><link>https://example.invalid/host</link>
<language>en</language><description>Preserve this channel metadata.</description>
<item><title>Version 0.2.0</title><sparkle:version>4</sparkle:version>
<sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
<description>Historical release &amp; notes</description>
<enclosure url="https://example.invalid/old.zip" length="12" type="application/octet-stream" sparkle:edSignature="old-signature" /></item>
<item><title>Version 0.1.2</title>
<enclosure url="https://example.invalid/older.zip" length="8" type="application/octet-stream" sparkle:version="3" sparkle:shortVersionString="0.1.2" sparkle:edSignature="older-signature" /></item>
</channel></rss>'''.encode()


class Response(io.BytesIO):
    def __init__(self, data):
        super().__init__(data)
        self.headers = {"Cache-Control": "no-cache, max-age=0", "Content-Type": "application/rss+xml"}


class FakeRunner:
    def __init__(self, fail_label=None):
        self.calls = []
        self.events = []
        self.fail_label = fail_label
        self.deployments = []

    def run(self, args, label, **kwargs):
        self.calls.append((args, label, kwargs))
        self.events.append(label)
        if label == self.fail_label:
            raise release.ReleaseError("Synthetic command failure")
        if label == "Create stapled download ZIP":
            Path(args[-1]).write_bytes(PAYLOAD)
        if label == "Sign Sparkle download":
            return SIGNATURE.encode(), b""
        if label == "Deploy the Sparkle feed to Cloudflare Pages":
            site = Path(args[args.index("deploy") + 1])
            self.deployments.append({
                "site": site,
                "files": {str(p.relative_to(site)): p.read_bytes() for p in site.rglob("*") if p.is_file()},
                "env": dict(kwargs["env"]),
            })
        return b"", b""


class FakeGitHub:
    def __init__(self, state, *, existing=True, body=None, asset=True, payload=PAYLOAD, feed=None):
        self.feed = historical_feed() if feed is None else feed
        self.blob = "current-feed-blob"
        self.calls = []
        self.asset_reads = 0
        self.payload = payload
        self.release_value = ({"id": 101, "draft": True, "body": body if body is not None else
                               f"Notes\n<!-- glassy-host-release:{state['id']} -->"} if existing else None)
        self.asset_values = ([{"id": 202, "name": "GlassyHost-0.3.0.zip", "size": len(payload),
                               "state": "uploaded"}] if asset else [])
        self.fail_feed_update = False

    def release(self, tag):
        self.calls.append(("release", tag))
        return self.release_value

    def assets(self, release_id):
        self.asset_reads += 1
        return self.asset_values

    def content(self, path):
        self.calls.append(("content", path))
        return self.feed, self.blob

    def request(self, method, path, data=None, **kwargs):
        self.calls.append((method, path, data, kwargs))
        if method == "POST" and path == "releases":
            self.release_value = {"id": 101, **data}
            return self.release_value
        if method == "POST" and path.startswith("releases/101/assets?"):
            self.payload = data
            self.asset_values = [{"id": 202, "name": "GlassyHost-0.3.0.zip", "size": len(data), "state": "uploaded"}]
            return self.asset_values[0]
        if method == "GET" and path == "releases/assets/202":
            assert kwargs.get("download")
            return self.payload
        if method == "PATCH" and path == "releases/101":
            self.release_value.update(data)
            return self.release_value
        if method == "PUT" and path.startswith("contents/"):
            if self.fail_feed_update:
                raise release.ReleaseError("Synthetic GitHub conflict (HTTP 409)")
            assert data["sha"] == self.blob
            self.feed = base64.b64decode(data["content"])
            self.blob = "updated-feed-blob"
            return {"commit": {"sha": "c" * 40}}
        if method == "GET" and path == "git/ref/heads/main":
            return {"object": {"sha": "d" * 40}}
        raise AssertionError(f"Unexpected mocked GitHub operation: {method} {path}")


class SyntheticCase(unittest.TestCase):
    def setUp(self):
        self.contexts = ExitStack()
        self.addCleanup(self.contexts.close)
        self.work = Path(self.contexts.enter_context(tempfile.TemporaryDirectory(prefix="release-test-")))
        self.state = make_state()
        self.archive = self.work / "GlassyHost-0.3.0.zip"
        self.archive.write_bytes(PAYLOAD)
        self.runner = FakeRunner()
        self.saved = []
        self.live_feed_requests = []
        self.contexts.enter_context(patch.dict(os.environ, {}, clear=True))
        # Any unmocked command, network access, or credential operation fails the test.
        self.process = self.contexts.enter_context(patch.object(release.subprocess, "run", side_effect=AssertionError("Real subprocess forbidden")))
        self.contexts.enter_context(patch.object(release.urllib.request, "urlopen", side_effect=AssertionError("Real HTTP forbidden")))
        self.contexts.enter_context(patch.object(release.urllib.request, "build_opener", side_effect=AssertionError("Real HTTP opener forbidden")))
        self.keychain = self.contexts.enter_context(patch.object(release, "CredentialStore", side_effect=AssertionError("Real Keychain forbidden")))
        self.contexts.enter_context(patch.object(release, "import_signing_identity", side_effect=AssertionError("Real P12 import forbidden")))

    def save(self):
        self.saved.append(copy.deepcopy(self.state))

    def without_final_signature(self):
        for field in ("sha256", "length", "signature"):
            self.state.pop(field, None)

    def allow_live_feed(self, github):
        def respond(request, *args, **kwargs):
            self.live_feed_requests.append(request)
            return Response(github.feed)

        return patch.object(release.urllib.request, "urlopen", side_effect=respond)


class AppcastTests(SyntheticCase):
    def test_new_item_preserves_channel_metadata_and_every_historical_item(self):
        original = historical_feed()
        _, before = release.parse_feed(original)
        _, after = release.parse_feed(release.updated_feed(original, self.state))
        self.assertEqual(after.findtext("title"), before.findtext("title"))
        self.assertEqual(after.findtext("link"), before.findtext("link"))
        self.assertEqual(after.findtext("description"), before.findtext("description"))
        self.assertEqual(after.findtext("language"), "en")
        self.assertEqual([ET.tostring(i) for i in after.findall("item")[1:]],
                         [ET.tostring(i) for i in before.findall("item")])
        newest = after.findall("item")[0]
        self.assertEqual(newest.findtext(f"{{{release.SPARKLE}}}version"), "5")
        self.assertEqual(newest.findtext(f"{{{release.SPARKLE}}}shortVersionString"), "0.3.0")
        self.assertEqual(newest.findtext(f"{{{release.SPARKLE}}}minimumSystemVersion"), "14.0")
        self.assertEqual(newest.find("enclosure").attrib["length"], str(len(PAYLOAD)))
        self.assertIn("&amp;", newest.findtext("description"))

    def test_downgrades_and_reusing_a_version_or_build_are_rejected(self):
        for version, build in (("0.3.0", "3"), ("0.3.0", "4"), ("0.1.5", "6"), ("0.2.0", "6")):
            with self.subTest(version=version, build=build):
                state = dict(self.state, version=version, build=build)
                with self.assertRaises(release.ReleaseError):
                    release.updated_feed(historical_feed(), state)

    def test_identical_existing_release_is_byte_for_byte_idempotent(self):
        first = release.updated_feed(historical_feed(), self.state)
        self.assertEqual(release.updated_feed(first, self.state), first)

    def test_numeric_equivalent_existing_build_does_not_duplicate_item(self):
        first = release.updated_feed(historical_feed(), self.state)
        equivalent = first.replace(b"<sparkle:version>5</sparkle:version>",
                                   b"<sparkle:version>5.0</sparkle:version>")
        self.assertEqual(release.updated_feed(equivalent, self.state), equivalent)

    def test_conflicting_existing_signature_length_or_url_is_rejected(self):
        first = release.updated_feed(historical_feed(), self.state)
        for field, value in (("signature", base64.b64encode(b"x" * 64).decode()),
                             ("length", len(PAYLOAD) + 1), ("download_url", "https://example.invalid/different.zip")):
            with self.subTest(field=field):
                with self.assertRaises(release.ReleaseError):
                    release.updated_feed(first, dict(self.state, **{field: value}))

    def test_entities_and_malformed_xml_are_rejected_before_processing(self):
        for data in (b"<rss>", b"<!DOCTYPE rss><rss><channel/></rss>",
                     b"<!ENTITY external SYSTEM 'https://example.invalid'><rss><channel/></rss>"):
            with self.subTest(data=data):
                with self.assertRaises(release.ReleaseError):
                    release.parse_feed(data)


class SignatureAndFinalizeTests(SyntheticCase):
    def test_exported_sparkle_secret_formats_and_invalid_data_are_redacted(self):
        for length in (32, 96):
            release.validate_sparkle_secret(base64.b64encode(b"k" * length).decode())
        for secret in ("SYNTHETIC-DO-NOT-PRINT-!", base64.b64encode(b"short-secret").decode()):
            output = io.StringIO()
            with redirect_stdout(output), redirect_stderr(output):
                with self.assertRaises(release.ReleaseError) as error:
                    release.validate_sparkle_secret(secret)
            self.assertNotIn(secret, output.getvalue() + str(error.exception))

    def test_failed_sensitive_signer_does_not_print_or_persist_its_secret_output(self):
        sentinel = "SYNTHETIC-SECRET-MUST-NOT-LEAK"
        result = subprocess.CompletedProcess([], 1, stdout=sentinel.encode(), stderr=sentinel.encode())
        output = io.StringIO()
        with patch.object(release.subprocess, "run", return_value=result), redirect_stdout(output), redirect_stderr(output):
            with self.assertRaises(release.ReleaseError) as error:
                release.Runner(self.work).run(["synthetic-sign-update"], "Sign Sparkle download",
                                              stdin=sentinel.encode(), sensitive=True)
        self.assertNotIn(sentinel, output.getvalue() + str(error.exception))
        self.assertFalse((self.work / "last-command.log").exists())

    def test_finalize_requires_notary_accepted_before_any_commands(self):
        self.without_final_signature()
        for status in (None, "In Progress", "Invalid", "Rejected"):
            with self.subTest(status=status):
                self.state["notary_status"] = status
                with self.assertRaisesRegex(release.ReleaseError, "accepted"):
                    release.finalize(self.state, self.work, CONFIG, self.runner, PRIVATE_KEY, self.save)
        self.assertEqual(self.runner.calls, [])
        self.assertEqual(self.saved, [])

    def test_resume_also_requires_notary_accepted_even_for_matching_zip(self):
        self.state["notary_status"] = "Invalid"
        with self.assertRaisesRegex(release.ReleaseError, "accepted"):
            release.finalize(self.state, self.work, CONFIG, self.runner, PRIVATE_KEY, self.save)
        self.assertEqual(self.runner.calls, [])

    def test_stapling_validation_and_independent_public_key_check_precede_receipt(self):
        self.without_final_signature()
        self.state["notary_status"] = "Accepted"
        with patch.object(release, "validate_app", side_effect=lambda *a: self.runner.events.append("Validate app")):
            archive = release.finalize(self.state, self.work, CONFIG, self.runner, PRIVATE_KEY, self.save)
        self.assertEqual(archive.read_bytes(), PAYLOAD)
        self.assertEqual(self.runner.events, [
            "Staple notarization ticket", "Validate notarization ticket", "Validate app",
            "Verify Gatekeeper acceptance", "Create stapled download ZIP", "Sign Sparkle download",
            "Verify Sparkle signature against the app's public key",
        ])
        signer = next(c for c in self.runner.calls if c[1] == "Sign Sparkle download")
        self.assertEqual(signer[2]["stdin"], PRIVATE_KEY.encode())
        self.assertTrue(signer[2]["sensitive"])
        self.assertNotIn(PRIVATE_KEY, [str(a) for a in signer[0]])
        verifier = self.runner.calls[-1][0]
        self.assertEqual(verifier[-3:], [archive, SIGNATURE, CONFIG["sparkle_public_key"]])
        self.assertEqual(len(self.saved), 1)
        self.assertEqual(self.saved[0]["sha256"], hashlib.sha256(PAYLOAD).hexdigest())

    def test_stapler_or_independent_verifier_failure_cannot_record_publishable_zip(self):
        for failure in ("Staple notarization ticket", "Validate notarization ticket",
                        "Verify Sparkle signature against the app's public key"):
            with self.subTest(failure=failure):
                self.without_final_signature()
                self.state["notary_status"] = "Accepted"
                runner = FakeRunner(fail_label=failure)
                with patch.object(release, "validate_app"):
                    with self.assertRaises(release.ReleaseError):
                        release.finalize(self.state, self.work, CONFIG, runner, PRIVATE_KEY, self.save)
                self.assertNotIn("sha256", self.state)
                self.assertNotIn("signature", self.state)
                if failure.startswith("Staple") or failure.startswith("Validate notarization"):
                    self.assertNotIn("Create stapled download ZIP", runner.events)
        self.assertEqual(self.saved, [])

    def test_resuming_changed_or_missing_final_zip_refuses_new_bytes(self):
        self.state["notary_status"] = "Accepted"
        self.archive.write_bytes(b"changed-zip")
        for missing in (False, True):
            with self.subTest(missing=missing):
                if missing:
                    self.archive.unlink()
                with self.assertRaisesRegex(release.ReleaseError, "missing or changed"):
                    release.finalize(self.state, self.work, CONFIG, self.runner, PRIVATE_KEY, self.save)
        self.assertEqual(self.runner.calls, [])

    def test_resume_reuses_matching_final_zip_without_resigning(self):
        self.state["notary_status"] = "Accepted"
        result = release.finalize(self.state, self.work, CONFIG, self.runner, PRIVATE_KEY, self.save)
        self.assertEqual(result, self.archive)
        self.assertEqual(self.runner.events, ["Verify Sparkle signature against the app's public key"])
        self.assertEqual(self.runner.calls[0][0][-3:], [self.archive, SIGNATURE, CONFIG["sparkle_public_key"]])
        self.assertEqual(self.saved, [])

    def test_malformed_successful_signer_output_is_not_forwarded_or_disclosed(self):
        self.without_final_signature()
        self.state["notary_status"] = "Accepted"
        sentinel = "SYNTHETIC-SECRET-ECHOED-AS-INVALID-SIGNATURE"
        original_run = self.runner.run
        def command(args, label, **kwargs):
            if label == "Sign Sparkle download":
                return sentinel.encode(), b""
            return original_run(args, label, **kwargs)
        self.runner.run = command
        output = io.StringIO()
        with patch.object(release, "validate_app"), redirect_stdout(output), redirect_stderr(output):
            with self.assertRaisesRegex(release.ReleaseError, "valid Ed25519 signature") as error:
                release.finalize(self.state, self.work, CONFIG, self.runner, PRIVATE_KEY, self.save)
        self.assertNotIn(sentinel, output.getvalue() + str(error.exception))
        self.assertNotIn("Verify Sparkle signature against the app's public key", self.runner.events)
        self.assertNotIn("sha256", self.state)
        self.assertEqual(self.saved, [])

    def test_resumed_signature_must_still_match_the_embedded_public_key(self):
        self.state["notary_status"] = "Accepted"
        runner = FakeRunner(fail_label="Verify Sparkle signature against the app's public key")
        with self.assertRaises(release.ReleaseError):
            release.finalize(self.state, self.work, CONFIG, runner, PRIVATE_KEY, self.save)
        self.assertEqual(runner.events, ["Verify Sparkle signature against the app's public key"])
        self.assertEqual(self.saved, [])


class NotarizationTests(SyntheticCase):
    def test_submission_id_is_saved_before_wait_and_reused_after_timeout(self):
        submission_id = "12345678-1234-4234-8234-123456789abc"
        events = []
        runner = Mock()
        def command(args, label, **kwargs):
            events.append(label)
            if "submit" in args:
                return json.dumps({"id": submission_id}).encode(), b""
            self.assertEqual(self.state["notary_id"], submission_id)
            self.assertEqual(events[-2], "saved")
            raise release.ReleaseError("Synthetic wait timeout")
        runner.run.side_effect = command
        with self.assertRaises(release.ReleaseError):
            release.notarize(self.state, self.work, runner, [], lambda: events.append("saved"))
        self.assertEqual(self.state["notary_id"], submission_id)
        runner.reset_mock()
        runner.run.side_effect = None
        runner.run.return_value = (b'{"status":"Accepted"}', b"")
        release.notarize(self.state, self.work, runner, [], self.save)
        self.assertEqual(runner.run.call_count, 1)
        self.assertIn("wait", runner.run.call_args[0][0])
        self.assertEqual(self.state["notary_status"], "Accepted")

    def test_nonaccepted_response_is_saved_and_stops_release(self):
        self.state["notary_id"] = "12345678-1234-4234-8234-123456789abc"
        runner = Mock()
        runner.run.return_value = (b'{"status":"Invalid"}', b"")
        with self.assertRaisesRegex(release.ReleaseError, "not accepted"):
            release.notarize(self.state, self.work, runner, [], self.save)
        self.assertEqual(self.saved[-1]["notary_status"], "Invalid")


class XcodeNotarizationTests(SyntheticCase):
    def prepare_xcode_state(self, *, submitted=False):
        archive = self.work / "GlassyHost.xcarchive"
        archive.mkdir()
        (archive / "Info.plist").write_bytes(plistlib.dumps({"ArchiveVersion": 2}))
        (self.work / "Glassy Desk.app").mkdir()
        self.state.update(
            notarization_mode="xcode",
            package_archive=str(archive),
            xcode_notary_submitted=submitted,
            notary_status="In Progress" if submitted else None,
        )
        return archive

    def successful_runner(self, events):
        identity = CONFIG["identity"]
        fingerprint = "A" * 40

        def command(args, label, **kwargs):
            events.append(label)
            if label == "Resolve the Xcode notarization signing certificate":
                return f'  1) {fingerprint} "{identity}"\n'.encode(), b""
            if label == "Check for the notarized app from Xcode":
                export_path = Path(args[args.index("-exportPath") + 1])
                (export_path / "Glassy Desk.app").mkdir(parents=True)
                return b"", b"", 0
            if label == "Stage the notarized app returned by Xcode":
                shutil.copytree(Path(args[1]), Path(args[2]))
            return b"", b""

        runner = Mock()
        runner.run.side_effect = command
        return runner

    def test_xcode_submission_then_export_precede_acceptance(self):
        archive = self.prepare_xcode_state()
        events = []
        runner = self.successful_runner(events)
        with patch.object(release, "validate_app", side_effect=lambda *a: events.append("Validate returned app")):
            release.xcode_notarize(self.state, self.work, CONFIG, runner, self.save,
                                   poll_attempts=1, poll_interval=0)

        self.assertEqual(events, [
            "Resolve the Xcode notarization signing certificate",
            "Submit archive through the signed-in Xcode account",
            "Check for the notarized app from Xcode",
            "Stage the notarized app returned by Xcode",
            "Validate returned app",
        ])
        submit = runner.run.call_args_list[1].args[0]
        self.assertEqual(submit[:4], ["xcodebuild", "-exportArchive", "-archivePath", archive])
        self.assertIn("-allowProvisioningUpdates", submit)
        options = plistlib.loads((self.work / "ExportOptions.plist").read_bytes())
        self.assertEqual(options, {
            "destination": "upload", "manageAppVersionAndBuildNumber": False,
            "method": "developer-id", "signingCertificate": "A" * 40,
            "signingStyle": "manual", "teamID": CONFIG["team_id"],
        })
        self.assertTrue(self.state["xcode_notary_submitted"])
        self.assertEqual(self.state["notary_status"], "Accepted")

    def test_resume_after_submission_never_submits_again(self):
        self.prepare_xcode_state(submitted=True)
        events = []
        runner = self.successful_runner(events)
        with patch.object(release, "validate_app"):
            release.xcode_notarize(self.state, self.work, CONFIG, runner, self.save,
                                   poll_attempts=1, poll_interval=0)
        self.assertNotIn("Submit archive through the signed-in Xcode account", events)
        self.assertNotIn("Resolve the Xcode notarization signing certificate", events)
        self.assertEqual(events[0], "Check for the notarized app from Xcode")

    def test_failed_export_stays_resumable_and_cannot_finalize(self):
        self.prepare_xcode_state(submitted=True)
        runner = Mock()
        runner.run.return_value = (b"", b"synthetic pending", 1)
        with self.assertRaisesRegex(release.ReleaseError, "Resume"):
            release.xcode_notarize(self.state, self.work, CONFIG, runner, self.save,
                                   poll_attempts=1, poll_interval=0)
        self.assertEqual(self.state["notary_status"], "In Progress")
        self.assertFalse(any(call.args[1] == "Stage the notarized app returned by Xcode"
                             for call in runner.run.call_args_list))
        with self.assertRaisesRegex(release.ReleaseError, "accepted"):
            release.finalize(self.state, self.work, CONFIG, FakeRunner(), PRIVATE_KEY, self.save)

    def test_ci_rejects_saved_xcode_mode_before_credentials_or_commands(self):
        self.prepare_xcode_state()
        self.state["packaged"] = True
        (self.work / "state.json").write_text(json.dumps(self.state))
        args = argparse.Namespace(config=Path("synthetic-config"), resume=self.work, notes=None,
                                  identity=None, work_dir=None, dry_run=False,
                                  xcode_notarization=False)
        with patch.dict(os.environ, {"CI": "true"}), \
             patch.object(release, "read_config", return_value=CONFIG), \
             patch.object(release, "Secrets", side_effect=AssertionError("credentials accessed")):
            with self.assertRaisesRegex(release.ReleaseError, "local-only"):
                release.execute(args)
        self.process.assert_not_called()


class AssetPublicationTests(SyntheticCase):
    def test_unknown_existing_release_is_never_modified(self):
        github = FakeGitHub(self.state, body="A release created outside this run")
        with self.assertRaisesRegex(release.ReleaseError, "not owned"):
            release.publish_asset(self.state, self.archive, github, self.save)
        self.assertEqual(github.asset_reads, 0)
        self.assertFalse(any(c[0] in ("POST", "PATCH", "PUT") for c in github.calls))

    def test_conflicting_asset_size_state_duplicate_or_bytes_is_never_overwritten(self):
        for mode in ("size", "incomplete", "duplicate", "digest"):
            with self.subTest(mode=mode):
                github = FakeGitHub(self.state)
                if mode == "size":
                    github.asset_values[0]["size"] += 1
                elif mode == "incomplete":
                    github.asset_values[0]["state"] = "starter"
                elif mode == "duplicate":
                    github.asset_values.append(dict(github.asset_values[0], id=303))
                else:
                    github.payload = b"x" * len(PAYLOAD)
                with patch.object(release, "verify_public_download") as public:
                    with self.assertRaises(release.ReleaseError):
                        release.publish_asset(self.state, self.archive, github, self.save)
                public.assert_not_called()
                self.assertFalse(any(c[0] in ("POST", "PATCH", "PUT") for c in github.calls))
                self.assertNotIn("asset_published", self.state)

    def test_matching_owned_asset_is_reused_and_public_bytes_verified(self):
        github = FakeGitHub(self.state)
        with patch.object(release, "verify_public_download") as public:
            release.publish_asset(self.state, self.archive, github, self.save)
        public.assert_called_once_with(self.state["download_url"], self.state["sha256"], self.state["length"])
        self.assertFalse(any(c[0] == "POST" for c in github.calls))
        self.assertTrue(self.state["asset_published"])
        self.assertFalse(github.release_value["draft"])

    def test_new_release_is_draft_until_uploaded_asset_bytes_match(self):
        github = FakeGitHub(self.state, existing=False, asset=False)
        with patch.object(release, "verify_public_download"):
            release.publish_asset(self.state, self.archive, github, self.save)
        requests = [c for c in github.calls if c[0] in ("POST", "GET", "PATCH")]
        self.assertEqual([c[0] for c in requests], ["POST", "POST", "GET", "PATCH"])
        self.assertTrue(requests[0][2]["draft"])
        self.assertEqual(requests[0][2]["target_commitish"], self.state["distribution_base"])
        self.assertEqual(requests[1][2], PAYLOAD)
        self.assertFalse(requests[-1][2]["draft"])

    def test_public_download_length_and_digest_must_both_match(self):
        for data in (PAYLOAD + b"extra", PAYLOAD[:-1], b"x" * len(PAYLOAD)):
            with self.subTest(data=data):
                opener = Mock()
                opener.open.return_value = Response(data)
                with patch.object(release.urllib.request, "build_opener", return_value=opener):
                    with self.assertRaises(release.ReleaseError):
                        release.verify_public_download(self.state["download_url"], self.state["sha256"], len(PAYLOAD))

    def test_public_download_failure_stops_execute_before_feed_publication(self):
        self.state.update(packaged=True, notary_status="Accepted")
        (self.work / "state.json").write_text(json.dumps(self.state))
        github = FakeGitHub(self.state)
        credentials = Mock()
        credentials.get.side_effect = lambda account, *a, **k: PRIVATE_KEY if account == "sparkle-key" else "synthetic-token"
        @contextmanager
        def auth(_):
            yield []
        args = argparse.Namespace(config=Path("synthetic-config"), resume=self.work, notes=None,
                                  identity=None, work_dir=None, dry_run=False)
        with ExitStack() as stack:
            stack.enter_context(patch.object(release, "read_config", return_value=CONFIG))
            stack.enter_context(patch.object(release.sys, "platform", "darwin"))
            stack.enter_context(patch.object(release.shutil, "which", return_value="/synthetic/tool"))
            stack.enter_context(patch.object(release, "Secrets", return_value=credentials))
            stack.enter_context(patch.object(release, "GitHub", return_value=github))
            stack.enter_context(patch.object(release, "notary_auth", auth))
            stack.enter_context(patch.object(release, "Runner", return_value=self.runner))
            stack.enter_context(patch.object(release, "verify_public_download", side_effect=release.ReleaseError("Synthetic public digest mismatch")))
            publish_feed = stack.enter_context(patch.object(release, "publish_feed"))
            stack.enter_context(redirect_stdout(io.StringIO()))
            with self.assertRaisesRegex(release.ReleaseError, "public digest mismatch"):
                release.execute(args)
        publish_feed.assert_not_called()
        self.assertFalse(any(c[0] == "PUT" for c in github.calls))


class FeedDeploymentTests(SyntheticCase):
    def test_deployment_contains_only_feed_and_headers_and_scoped_token(self):
        (self.work / "private-secret.p8").write_text("SYNTHETIC-PRIVATE-MATERIAL")
        github = FakeGitHub(self.state)
        env = {"GH_TOKEN": "synthetic-github", "SPARKLE_PRIVATE_KEY": PRIVATE_KEY,
               "CODESIGN_P12_PASSWORD": "synthetic-p12-password", "PATH": "/synthetic/bin"}
        with patch.dict(os.environ, env), self.allow_live_feed(github):
            release.publish_feed(self.state, self.work, CONFIG, github, self.runner,
                                 "synthetic-cloudflare-token", "a" * 32, self.save)
        self.assertEqual(len(self.runner.deployments), 1)
        deployment = self.runner.deployments[0]
        self.assertEqual(set(deployment["files"]), {"glassy-host/appcast.xml", "_headers"})
        self.assertEqual(deployment["files"]["glassy-host/appcast.xml"], github.feed)
        self.assertIn(b"application/rss+xml", deployment["files"]["_headers"])
        self.assertFalse(deployment["site"].exists())
        self.assertEqual(deployment["env"]["CLOUDFLARE_API_TOKEN"], "synthetic-cloudflare-token")
        for key in ("GH_TOKEN", "SPARKLE_PRIVATE_KEY", "CODESIGN_P12_PASSWORD"):
            self.assertNotIn(key, deployment["env"])
        command = self.runner.calls[-1]
        self.assertTrue(command[2]["sensitive"])
        self.assertNotIn("--json", command[0])
        self.assertIn("--package=wrangler@4.128.0", command[0])
        self.assertGreaterEqual(len(self.live_feed_requests), 1)
        live_request = self.live_feed_requests[0]
        self.assertEqual(live_request.full_url, CONFIG["feed_url"])
        self.assertEqual(live_request.get_header("User-agent"), "GlassyHost-Release/1.0")
        self.assertEqual(live_request.get_header("Accept"), "application/rss+xml")
        self.assertEqual(live_request.get_header("Cache-control"), "no-cache")
        self.assertIsNone(live_request.get_header("Authorization"))
        self.assertFalse(any("cloudflare" in name.lower() for name, _ in live_request.header_items()))
        self.assertTrue(self.state["complete"])
        put = next(c for c in github.calls if c[0] == "PUT")
        self.assertEqual(put[2]["sha"], "current-feed-blob")

    def test_feed_conflict_does_not_deploy_or_overwrite_remote_data(self):
        github = FakeGitHub(self.state)
        github.fail_feed_update = True
        before = github.feed
        with self.assertRaisesRegex(release.ReleaseError, "409"):
            release.publish_feed(self.state, self.work, CONFIG, github, self.runner,
                                 "synthetic-cloudflare-token", "a" * 32, self.save)
        self.assertEqual(github.feed, before)
        self.assertEqual(self.runner.calls, [])
        self.assertNotIn("complete", self.state)

    def test_existing_exact_feed_retries_deployment_without_duplicate_commit(self):
        current = release.updated_feed(historical_feed(), self.state)
        github = FakeGitHub(self.state, feed=current)
        with self.allow_live_feed(github):
            release.publish_feed(self.state, self.work, CONFIG, github, self.runner,
                                 "synthetic-cloudflare-token", "a" * 32, self.save)
        self.assertFalse(any(c[0] == "PUT" for c in github.calls))
        self.assertEqual(self.state["feed_commit"], "d" * 40)
        self.assertEqual(github.feed, current)
        self.assertTrue(self.state["complete"])


class EnvironmentAndDryRunTests(SyntheticCase):
    def test_unrelated_children_receive_no_release_credentials(self):
        secret_names = ("GH_TOKEN", "GITHUB_TOKEN", "CLOUDFLARE_API_TOKEN", "SPARKLE_PRIVATE_KEY",
                        "NOTARY_PRIVATE_KEY", "NOTARY_KEY_PATH", "CODESIGN_P12_BASE64",
                        "CODESIGN_P12_PASSWORD", "APPLE_PASSWORD", "APPLE_APP_SPECIFIC_PASSWORD", "ASC_PRIVATE_KEY")
        env = {key: f"synthetic-secret-{key}" for key in secret_names}
        env.update(PATH="/synthetic/bin", LANG="en_US.UTF-8", CI="false", GH_PROMPT_DISABLED="0")
        with patch.dict(os.environ, env):
            clean = release.clean_environment()
        for key in secret_names:
            self.assertNotIn(key, clean)
        self.assertEqual(clean["PATH"], "/synthetic/bin")
        self.assertEqual(clean["LANG"], "en_US.UTF-8")
        self.assertEqual(clean["CI"], "true")
        self.assertEqual(clean["GH_PROMPT_DISABLED"], "1")
        self.assertEqual(clean["GIT_TERMINAL_PROMPT"], "0")

    def test_ci_secrets_use_environment_without_opening_keychain(self):
        with patch.dict(os.environ, {"CI": "true", "GH_TOKEN": "synthetic-ci-token"}):
            credentials = release.Secrets()
            self.assertEqual(credentials.get("github-token", ["GH_TOKEN"]), "synthetic-ci-token")
            with self.assertRaisesRegex(release.ReleaseError, "Missing"):
                credentials.get("sparkle-key", ["SPARKLE_PRIVATE_KEY"])
        self.keychain.assert_not_called()

    def test_dry_run_reads_local_metadata_without_commands_network_credentials_or_workspace(self):
        project = self.work / "synthetic-project"
        info = project / "GlassyHost/Support/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({
            "CFBundleIdentifier": CONFIG["bundle_id"], "SUFeedURL": CONFIG["feed_url"],
            "SUPublicEDKey": CONFIG["sparkle_public_key"], "CFBundleShortVersionString": "0.3.0",
            "CFBundleVersion": "5", "LSMinimumSystemVersion": "14.0",
        }))
        config = self.work / "config.json"
        config.write_text(json.dumps(CONFIG))
        notes = self.work / "notes.md"
        notes.write_text("Synthetic release notes.")
        output_work = self.work / "must-not-be-created"
        output = io.StringIO()
        with patch.object(release, "ROOT", project), patch.object(release, "Secrets", side_effect=AssertionError("Dry run accessed secrets")) as secrets_factory:
            with patch.object(release, "GitHub", side_effect=AssertionError("Dry run accessed GitHub")) as github_factory:
                with redirect_stdout(output), redirect_stderr(output):
                    status = release.main(["--dry-run", "--notes", str(notes), "--config", str(config),
                                           "--work-dir", str(output_work)])
        self.assertEqual(status, 0, output.getvalue())
        self.assertIn("Dry run", output.getvalue())
        self.assertIn("notarytool API key", output.getvalue())
        self.assertNotIn("signed-in Xcode account", output.getvalue())
        self.assertFalse(output_work.exists())
        self.process.assert_not_called()
        self.keychain.assert_not_called()
        secrets_factory.assert_not_called()
        github_factory.assert_not_called()


if __name__ == "__main__":
    unittest.main()
