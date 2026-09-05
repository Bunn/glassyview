"""Offline end-to-end release orchestration: real receipts, fake external services."""
import base64
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_host as release


OLD_FEED = b'''<?xml version="1.0"?><rss version="2.0"
xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<title>Glassy Host</title><item><title>Old release</title><sparkle:version>3</sparkle:version>
<sparkle:shortVersionString>0.1.2</sparkle:shortVersionString></item></channel></rss>'''
SIGNATURE = base64.b64encode(bytes(64)).decode()


class ServiceFixture:
    def __init__(self, work):
        self.work = work
        self.feed = OLD_FEED
        self.release_value = None
        self.asset = None
        self.archive = None
        self.deployed = None
        self.commands = []
        self.events = []
        self.apple_status = "Accepted"
        self.interrupt_wait = False
        self.version = plistlib.loads((release.ROOT / "GlassyHost/Support/Info.plist").read_bytes())["CFBundleShortVersionString"]

    def content(self, path):
        return self.feed, "blob-before"

    def release(self, tag):
        return self.release_value

    def assets(self, release_id):
        return [self.asset] if self.asset else []

    def request(self, method, path, data=None, **options):
        if method == "GET" and path.startswith("git/ref/"):
            return {"object": {"sha": "a" * 40}}
        if method == "POST" and path == "releases":
            self.events.append("draft")
            self.release_value = {**data, "id": 1}
            return self.release_value
        if method == "POST" and path.startswith("releases/1/assets?"):
            self.events.append("asset")
            self.archive = data
            self.asset = {"id": 2, "name": f"GlassyHost-{self.version}.zip", "size": len(data), "state": "uploaded"}
            return self.asset
        if method == "GET" and path == "releases/assets/2":
            return self.archive
        if method == "PATCH" and path == "releases/1":
            self.events.append("publish")
            self.release_value.update(data)
            return self.release_value
        if method == "PUT" and path == "contents/glassy-host/appcast.xml":
            self.events.append("feed")
            self.feed = base64.b64decode(data["content"])
            return {"commit": {"sha": "b" * 40}}
        raise AssertionError((method, path))

    def run(self, args, label, **options):
        args = [str(arg) for arg in args]
        self.commands.append(args)
        if args[0] == "bash":
            self.events.append("compile")
            package_dir = self.work / "compiled"
            app = package_dir / "Glassy Desk.app"
            (app / "Contents").mkdir(parents=True)
            shutil.copyfile(release.ROOT / "GlassyHost/Support/Info.plist", app / "Contents/Info.plist")
            submission = package_dir / "submission.zip"
            submission.write_bytes(b"submission-before-stapling")
            (self.work / "package.json").write_text(json.dumps({
                "app": str(app), "submission_zip": str(submission), "sparkle_tools": str(package_dir),
            }))
        elif args[0] == "ditto" and "-c" not in args:
            shutil.copytree(args[1], args[2])
        elif args[:3] == ["xcrun", "notarytool", "submit"]:
            self.events.append("submit")
            return json.dumps({"id": "12345678-1234-1234-1234-123456789abc"}).encode(), b""
        elif args[:3] == ["xcrun", "notarytool", "wait"]:
            self.events.append("wait")
            if self.interrupt_wait:
                self.interrupt_wait = False
                raise release.ReleaseError("simulated wait timeout")
            return json.dumps({"status": self.apple_status}).encode(), b""
        elif args[:3] == ["xcrun", "stapler", "staple"]:
            self.events.append("staple")
            (self.work / "Glassy Desk.app/ticket").write_bytes(b"notarized")
        elif args[0] == "ditto" and "-c" in args:
            self.events.append("zip")
            assert (self.work / "Glassy Desk.app/ticket").read_bytes() == b"notarized"
            Path(args[-1]).write_bytes(b"final-stapled-archive")
        elif args[0].endswith("/sign_update"):
            self.events.append("sign")
            assert options["sensitive"] is True
            return SIGNATURE.encode(), b""
        elif args[0] == "swift":
            self.events.append("verify-signature")
        elif args[0] == "/usr/bin/codesign" and "-d" in args:
            return b"", (b"Authority=Developer ID Application: Test\nTeamIdentifier=B2RUA6XMHC\n"
                         b"Timestamp=Sep 3 2026\nCodeDirectory flags=0x10000(runtime)\n")
        elif args[0] == "npx":
            self.events.append("deploy")
            site = Path(args[args.index("deploy") + 1])
            assert sorted(str(p.relative_to(site)) for p in site.rglob("*") if p.is_file()) == [
                "_headers", "glassy-host/appcast.xml"]
            self.deployed = (site / "glassy-host/appcast.xml").read_bytes()
        return b"", b""

    def public_response(self, *args, **kwargs):
        response = io.BytesIO(self.deployed)
        response.headers = {"Cache-Control": "no-cache", "Content-Type": "application/rss+xml"}
        return response


class ReleasePipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name) / "release"
        self.notes = Path(self.temp.name) / "notes.md"
        self.notes.write_text("A synthetic release.\n")
        self.service = ServiceFixture(self.work)
        self.environment = {
            "CI": "true", "GH_TOKEN": "fake-github", "CLOUDFLARE_API_TOKEN": "fake-cloudflare",
            "CLOUDFLARE_ACCOUNT_ID": "a" * 32,
            "SPARKLE_PRIVATE_KEY": base64.b64encode(bytes(32)).decode(),
        }
        self.patches = contextlib.ExitStack()
        self.addCleanup(self.patches.close)
        self.patches.enter_context(patch.dict(os.environ, self.environment, clear=True))
        self.patches.enter_context(patch.object(release.sys, "platform", "darwin"))
        self.patches.enter_context(patch.object(release.shutil, "which", return_value="/mock/tool"))
        self.patches.enter_context(patch.object(release, "GitHub", return_value=self.service))
        self.patches.enter_context(patch.object(release, "Runner", return_value=self.service))
        self.signing = self.patches.enter_context(patch.object(
            release, "signing_environment", side_effect=lambda *args: contextlib.nullcontext({})))
        self.notary_auth = self.patches.enter_context(patch.object(
            release, "notary_auth", side_effect=lambda *args: contextlib.nullcontext(["--key", "/mock/key.p8"])))
        self.download = self.patches.enter_context(patch.object(release, "verify_public_download"))
        self.patches.enter_context(patch.object(release.urllib.request, "urlopen", self.service.public_response))
        self.patches.enter_context(contextlib.redirect_stdout(io.StringIO()))
        self.patches.enter_context(contextlib.redirect_stderr(io.StringIO()))

    def start(self):
        return release.main(["--notes", str(self.notes), "--work-dir", str(self.work)])

    def resume(self):
        return release.main(["--resume", str(self.work)])

    def test_full_command_compiles_notarizes_and_publishes_only_verified_download(self):
        self.assertEqual(self.start(), 0)
        self.assertEqual(self.service.events, ["compile", "submit", "wait", "staple", "zip", "sign",
                                               "verify-signature", "draft", "asset", "publish", "feed", "deploy"])
        state = json.loads((self.work / "state.json").read_text())
        self.assertTrue(state["complete"])
        self.assertEqual(state["notary_status"], "Accepted")
        self.assertEqual(len(release.parse_feed(self.service.feed)[1].findall("item")), 2)
        self.assertEqual(self.work.joinpath("state.json").stat().st_mode & 0o777, 0o600)
        self.assertNotIn("fake-github", json.dumps(state))
        self.assertNotIn("fake-cloudflare", json.dumps(state))

    def test_notary_rejection_stops_before_any_publication(self):
        self.service.apple_status = "Invalid"
        self.assertEqual(self.start(), 1)
        self.assertEqual(self.service.events, ["compile", "submit", "wait"])
        self.assertIsNone(self.service.release_value)
        self.assertEqual(self.service.feed, OLD_FEED)

    def test_wait_timeout_resumes_same_submission_without_compile_or_resubmit(self):
        self.service.interrupt_wait = True
        self.assertEqual(self.start(), 1)
        state = json.loads((self.work / "state.json").read_text())
        self.assertEqual(state["notary_id"], "12345678-1234-1234-1234-123456789abc")
        self.assertEqual(self.resume(), 0)
        self.assertEqual(self.service.events.count("compile"), 1)
        self.assertEqual(self.service.events.count("submit"), 1)
        self.assertEqual(self.service.events.count("wait"), 2)

    def test_publish_resume_reuses_artifact_and_needs_no_signing_or_notary_secrets(self):
        self.download.side_effect = release.ReleaseError("public download is not ready")
        self.assertEqual(self.start(), 1)
        self.assertEqual(self.service.feed, OLD_FEED)
        archive = self.work / f"GlassyHost-{self.service.version}.zip"
        archive_before = archive.read_bytes()
        self.download.side_effect = None
        os.environ.pop("SPARKLE_PRIVATE_KEY")
        self.notary_auth.side_effect = AssertionError("must not request notarization credentials")
        self.signing.side_effect = AssertionError("must not import signing credentials")
        self.assertEqual(self.resume(), 0)
        self.assertEqual(archive.read_bytes(), archive_before)
        for event in ("compile", "submit", "staple", "zip", "sign", "asset"):
            self.assertEqual(self.service.events.count(event), 1, event)

    def test_resume_before_completed_packaging_never_rebuilds(self):
        self.signing.side_effect = release.ReleaseError("missing signing credential")
        self.assertEqual(self.start(), 1)
        self.signing.side_effect = AssertionError("resume must not start compilation")
        self.assertEqual(self.resume(), 1)
        self.assertNotIn("compile", self.service.events)


if __name__ == "__main__":
    unittest.main()
