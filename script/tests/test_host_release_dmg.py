"""Installer trust boundaries and resumable receipts, without Apple credentials."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import host_release_dmg as installer
import release_host as release


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.dmg_work = self.work / "dmg"
        self.dmg_work.mkdir()
        self.source = self.work / "GlassyHost-1.2.3.zip"
        self.source.write_bytes(b"immutable sparkled app")
        self.config = {"repository": "Bunn/GlassyDesk-Host", "team_id": "B2RUA6XMHC"}
        self.parent = dict(schema=1, id="parent-release", config=self.config, version="1.2.3", build="20",
                           minimum_system="14.0", identity="Developer ID Application: Example",
                           notarization_mode="xcode", notary_status="Accepted", asset_published=True,
                           sha256=release.digest(self.source), length=self.source.stat().st_size,
                           tag="v1.2.3", download_url="https://example.com/original.zip")
        self.state = {key: self.parent[key] for key in
                      ("schema", "config", "version", "build", "minimum_system", "identity", "notarization_mode")}
        self.state.update(parent_id=self.parent["id"], source_sha256=self.parent["sha256"], notary_status="Accepted")
        self.submission = self.dmg_work / "submission.dmg"
        self.submission.write_bytes(b"signed disk image")
        self.state["signed_sha256"] = release.digest(self.submission)
        self.dmg = self.dmg_work / "GlassyDesk-1.2.3.dmg"
        self.credentials = Mock()
        self.credentials.get.side_effect = AssertionError("Unexpected credentials read")
        self.runner = Mock()
        self.runner.run.return_value = b"", b""
        self.patches = contextlib.ExitStack()
        self.addCleanup(self.patches.close)
        self.patches.enter_context(patch.object(release, "is_ci_environment", return_value=False))
        self.patches.enter_context(patch.object(release, "Runner", return_value=self.runner))
        self.validation = self.patches.enter_context(patch.object(installer, "validate_dmg"))
        self.patches.enter_context(contextlib.redirect_stdout(io.StringIO()))
        self.save()

    def save(self):
        (self.dmg_work / "state.json").write_text(json.dumps(self.state))

    def prepare(self):
        return installer.prepare(self.parent, self.work, self.config, self.credentials)

    def test_changed_sparkle_zip_cannot_be_used_for_an_installer(self):
        self.source.write_bytes(b"different app")
        with self.assertRaisesRegex(release.ReleaseError, "ZIP is missing or changed"):
            self.prepare()
        self.runner.run.assert_not_called()

    def test_changed_submission_is_not_resigned_or_resubmitted(self):
        self.submission.write_bytes(b"different signed image")
        with self.assertRaisesRegex(release.ReleaseError, "submission changed"):
            self.prepare()
        self.runner.run.assert_not_called()

    def test_parent_archive_acceptance_is_not_enough_without_a_dmg_ticket(self):
        self.runner.run.side_effect = release.ReleaseError("DMG ticket missing")
        with self.assertRaisesRegex(release.ReleaseError, "DMG ticket missing"):
            self.prepare()
        receipt = json.loads((self.dmg_work / "state.json").read_text())
        self.assertNotIn("sha256", receipt)
        self.assertNotIn("asset_published", receipt)

    def test_interrupted_staple_retries_immutable_submission_without_signing_or_auth(self):
        self.validation.side_effect = release.ReleaseError("Interrupted validation")
        with self.assertRaises(release.ReleaseError):
            self.prepare()
        self.dmg.write_bytes(b"partially stapled image")
        self.validation.side_effect = None
        dmg, state = self.prepare()
        self.assertEqual(dmg.read_bytes(), self.submission.read_bytes())
        self.assertEqual(state["sha256"], release.digest(dmg))
        self.assertEqual(self.submission.read_bytes(), b"signed disk image")
        self.credentials.get.assert_not_called()
        self.assertTrue(all(call.args[0][:3] == ["xcrun", "stapler", "staple"]
                            for call in self.runner.run.call_args_list))

    def test_completed_installer_is_revalidated_without_rebuilding(self):
        self.dmg.write_bytes(b"final signed and stapled image")
        self.state.update(sha256=release.digest(self.dmg), length=self.dmg.stat().st_size)
        self.save()
        self.prepare()
        self.validation.assert_called_once_with(self.dmg, self.config, self.parent, self.runner)
        self.runner.run.assert_not_called()
        self.credentials.get.assert_not_called()

    def test_changed_completed_installer_is_never_replaced(self):
        self.dmg.write_bytes(b"final image")
        self.state.update(sha256=release.digest(self.dmg), length=self.dmg.stat().st_size)
        self.save()
        self.dmg.write_bytes(b"changed image")
        with self.assertRaisesRegex(release.ReleaseError, "refusing different bytes"):
            self.prepare()
        self.assertEqual(self.dmg.read_bytes(), b"changed image")

    def test_installer_publish_preserves_parent_receipt_and_download(self):
        self.dmg.write_bytes(b"final image")
        self.state.update(sha256=release.digest(self.dmg), length=self.dmg.stat().st_size)
        before = dict(self.parent)
        github = Mock()
        def publish_asset(artifact, dmg, remote, save):
            self.assertEqual(artifact["id"], self.parent["id"])
            self.assertNotIn("asset_published", artifact)
            self.assertTrue(artifact["download_url"].endswith("/GlassyDesk-1.2.3.dmg"))
            self.assertEqual(remote, github)
            artifact.update(asset_id=42, asset_published=True)
            save()
        with patch.object(release, "publish_asset", side_effect=publish_asset):
            installer.publish(self.parent, self.dmg, self.state, github)
        self.assertEqual(self.parent, before)
        self.assertTrue(json.loads((self.dmg_work / "state.json").read_text())["complete"])

    def test_changed_image_between_validation_and_upload_is_rejected(self):
        self.dmg.write_bytes(b"final image")
        self.state.update(sha256=release.digest(self.dmg), length=self.dmg.stat().st_size)
        self.dmg.write_bytes(b"different image")
        github = Mock()
        with self.assertRaisesRegex(release.ReleaseError, "changed before publication"):
            installer.publish(self.parent, self.dmg, self.state, github)
        github.assert_not_called()

    def test_add_installer_dry_run_does_not_load_credentials_or_create_files(self):
        (self.work / "state.json").write_text(json.dumps(self.parent))
        before = sorted(self.work.rglob("*"))
        with patch.object(release, "Secrets", side_effect=AssertionError("Read credentials")):
            installer.add_installer(self.work, self.config, dry_run=True)
        self.assertEqual(sorted(self.work.rglob("*")), before)

    def test_dmg_upload_uses_the_disk_image_mime_type(self):
        client = release.GitHub("synthetic-token", {**self.config, "branch": "main"})
        client.opener = Mock()
        client.opener.open.return_value = io.BytesIO(b"{}")
        client.request("POST", "releases/1/assets?name=GlassyDesk-1.2.3.dmg", b"dmg", binary=True)
        request = client.opener.open.call_args.args[0]
        self.assertEqual(request.get_header("Content-type"), "application/x-apple-diskimage")


if __name__ == "__main__":
    unittest.main()
