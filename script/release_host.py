#!/usr/bin/env python3
"""Build and publish Glassy Desk. Standard library only; no credentials in state."""
from __future__ import annotations

import argparse
import base64
import binascii
import contextlib
import datetime as dt
import email.utils
import fcntl
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET

from host_release_credentials import CredentialError, CredentialStore, import_signing_identity

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
SECRET_ENV = {
    "GH_TOKEN", "GITHUB_TOKEN", "CLOUDFLARE_API_TOKEN", "SPARKLE_PRIVATE_KEY",
    "NOTARY_PRIVATE_KEY", "NOTARY_KEY_PATH", "CODESIGN_P12_BASE64", "CODESIGN_P12_PASSWORD",
    "APPLE_APP_SPECIFIC_PASSWORD", "APPLE_PASSWORD", "ASC_PRIVATE_KEY",
}
XCODE_NOTARY_POLL_ATTEMPTS = 41
XCODE_NOTARY_POLL_INTERVAL = 30


class ReleaseError(Exception):
    pass


def numeric_version(value: str) -> tuple[int, int, int]:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
        raise ReleaseError("Version and build numbers must have one to three numeric components.")
    parts = tuple(int(p) for p in value.split("."))
    return parts + (0,) * (3 - len(parts))


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def write_private(path: Path, data: bytes) -> None:
    # Same-directory replace makes receipt updates atomic on interrupted runs.
    fd, temporary = tempfile.mkstemp(prefix=".release-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def clean_environment() -> dict[str, str]:
    environment = {k: v for k, v in os.environ.items() if k not in SECRET_ENV}
    environment.update(CI="true", GH_PROMPT_DISABLED="1", GIT_TERMINAL_PROMPT="0",
                       WRANGLER_SEND_METRICS="false")
    return environment


def is_ci_environment() -> bool:
    return any(os.environ.get(name, "").lower() not in ("", "0", "false", "no")
               for name in ("CI", "GITHUB_ACTIONS"))


class Runner:
    def __init__(self, work: Path):
        self.work = work

    def run(self, args, label, *, stdin=None, env=None, timeout=1800, sensitive=False,
            allow_failure=False, include_status=False):
        print(f"→ {label}", flush=True)
        try:
            result = subprocess.run([str(a) for a in args], input=stdin,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    env=env or clean_environment(), cwd=ROOT, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise ReleaseError(f"{label} timed out. Resume this release to continue.") from None
        except OSError:
            raise ReleaseError(f"Could not run {label}. Check the documented prerequisites.") from None
        if result.returncode and not allow_failure:
            # Some credential tools echo malformed secrets. Never print their output.
            if not sensitive:
                log = self.work / "last-command.log"
                write_private(log, result.stdout + result.stderr)
                raise ReleaseError(f"{label} failed; details: {log}")
            raise ReleaseError(f"{label} failed (credential-tool output withheld).")
        if include_status:
            return result.stdout, result.stderr, result.returncode
        return result.stdout, result.stderr


class Secrets:
    def __init__(self):
        self.ci = is_ci_environment()
        self.store = None

    def get(self, account, variables, *, required=True, strip=True):
        value = next((os.environ[v] for v in variables if v in os.environ), None)
        if value is None and not self.ci:
            if self.store is None:
                self.store = CredentialStore()
            value = self.store.get(account)
        if value is not None and strip:
            value = value.strip()
        if required and (value is None or (strip and not value)):
            raise ReleaseError(f"Missing {variables[0]}. Set a CI secret or import '{account}' into Keychain.")
        return value


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlparse(newurl).scheme != "https":
            raise ReleaseError("Refusing a non-HTTPS download redirect.")
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected:
            redirected.remove_header("Authorization")
        return redirected


class GitHub:
    def __init__(self, token, config):
        self.token = token
        self.repo = config["repository"]
        self.branch = config["branch"]
        self.opener = urllib.request.build_opener(SafeRedirect())

    def request(self, method, path, data=None, *, binary=False, missing=False, download=False):
        host = "uploads.github.com" if binary else "api.github.com"
        url = f"https://{host}/repos/{self.repo}/{path}"
        headers = {"Authorization": f"Bearer {self.token}", "User-Agent": "GlassyHost-Release",
                   "Accept": "application/octet-stream" if download else "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28"}
        payload = data if binary else json.dumps(data).encode() if data is not None else None
        if payload is not None:
            asset_name = urllib.parse.parse_qs(urllib.parse.urlparse(path).query).get("name", [""])[0]
            headers["Content-Type"] = ("application/x-apple-diskimage" if asset_name.endswith(".dmg")
                                       else "application/zip") if binary else "application/json"
        request = urllib.request.Request(url, data=payload, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=180) as response:
                body = response.read()
        except urllib.error.HTTPError as error:
            if missing and error.code == 404:
                return None
            raise ReleaseError(f"GitHub {method} failed (HTTP {error.code}); resume after resolving it.") from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise ReleaseError("GitHub request interrupted. Resume to reconcile remote state.") from None
        return body if download else json.loads(body)

    def content(self, path):
        value = self.request("GET", f"contents/{path}?ref={urllib.parse.quote(self.branch, safe='')}")
        if value.get("encoding") != "base64":
            raise ReleaseError("Unexpected distribution repository file encoding.")
        return base64.b64decode(value["content"]), value["sha"]

    def release(self, tag):
        return self.request("GET", f"releases/tags/{urllib.parse.quote(tag, safe='')}", missing=True)

    def assets(self, release_id):
        assets = []
        for page in range(1, 101):
            batch = self.request("GET", f"releases/{release_id}/assets?per_page=100&page={page}")
            assets.extend(batch)
            if len(batch) < 100:
                return assets
        raise ReleaseError("Too many assets in this release.")


def parse_feed(data):
    if len(data) > 4 * 1024 * 1024 or b"<!DOCTYPE" in data.upper() or b"<!ENTITY" in data.upper():
        raise ReleaseError("Invalid or oversized appcast.")
    try:
        root = ET.fromstring(data)
    except ET.ParseError:
        raise ReleaseError("The published appcast is not valid XML.") from None
    channel = root.find("channel")
    if root.tag != "rss" or channel is None:
        raise ReleaseError("The appcast must contain an RSS channel.")
    return root, channel


def check_feed(data, state, *, allow_existing=False):
    _, channel = parse_feed(data)
    for item in channel.findall("item"):
        enclosure = item.find("enclosure")
        attrs = enclosure.attrib if enclosure is not None else {}
        build = item.findtext(f"{{{SPARKLE}}}version") or attrs.get(f"{{{SPARKLE}}}version")
        version = item.findtext(f"{{{SPARKLE}}}shortVersionString") or attrs.get(f"{{{SPARKLE}}}shortVersionString")
        if not build:
            raise ReleaseError("An existing appcast item has no build number.")
        same = numeric_version(build) == numeric_version(state["build"])
        if same and allow_existing and version == state["version"] and attrs == {
            "url": state["download_url"], "length": str(state["length"]),
            "type": "application/octet-stream", f"{{{SPARKLE}}}edSignature": state["signature"],
        }:
            continue
        if numeric_version(build) >= numeric_version(state["build"]):
            raise ReleaseError("The host build must be newer than every published appcast build.")
        if version and numeric_version(version) >= numeric_version(state["version"]):
            raise ReleaseError("The host version must be newer than every published version; tags are immutable.")


def updated_feed(data, state):
    check_feed(data, state, allow_existing=True)
    root, channel = parse_feed(data)
    for item in channel.findall("item"):
        enclosure = item.find("enclosure")
        build = item.findtext(f"{{{SPARKLE}}}version")
        if not build and enclosure is not None:
            build = enclosure.get(f"{{{SPARKLE}}}version")
        if build and numeric_version(build) == numeric_version(state["build"]):
            return data
    item = ET.Element("item")
    for name, value in (
        ("title", f"Glassy Desk {state['version']}"), ("pubDate", state["pub_date"]),
        ("link", state["release_url"]), (f"{{{SPARKLE}}}version", state["build"]),
        (f"{{{SPARKLE}}}shortVersionString", state["version"]),
        (f"{{{SPARKLE}}}minimumSystemVersion", state["minimum_system"]),
        ("description", "<p>" + html.escape(state["notes"]).replace("\n", "<br>\n") + "</p>"),
    ):
        ET.SubElement(item, name).text = value
    ET.SubElement(item, "enclosure", {"url": state["download_url"], "length": str(state["length"]),
                  "type": "application/octet-stream", f"{{{SPARKLE}}}edSignature": state["signature"]})
    index = next((i for i, child in enumerate(channel) if child.tag == "item"), len(channel))
    channel.insert(index, item)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"


def validate_sparkle_secret(value):
    try:
        key = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error):
        raise ReleaseError("SPARKLE_PRIVATE_KEY must be the exported base64 Sparkle key.") from None
    if len(key) not in (32, 96):
        raise ReleaseError("SPARKLE_PRIVATE_KEY must decode to 32 or 96 bytes.")


def app_metadata(path, config):
    with path.open("rb") as source:
        info = plistlib.load(source)
    expected = {"CFBundleIdentifier": config["bundle_id"], "SUFeedURL": config["feed_url"],
                "SUPublicEDKey": config["sparkle_public_key"]}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ReleaseError(f"{key} differs from the release configuration.")
    for key in ("CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion"):
        numeric_version(info.get(key))
    return {"version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "minimum_system": info["LSMinimumSystemVersion"]}


def validate_app(app, config, state, run):
    if app_metadata(app / "Contents/Info.plist", config) != {
        key: state[key] for key in ("version", "build", "minimum_system")
    }:
        raise ReleaseError("The built app version differs from this release's recorded version.")
    run.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], "Verify app signature")
    _, details = run.run(["/usr/bin/codesign", "-d", "--verbose=4", app], "Inspect Developer ID signature")
    text = details.decode(errors="replace")
    if (f"TeamIdentifier={config['team_id']}\n" not in text or
            "Authority=Developer ID Application:" not in text or
            not re.search(r"flags=0x[0-9a-f]+\([^)]*runtime", text) or
            not re.search(r"^Timestamp=(?!none\s*$).+", text, re.MULTILINE)):
        raise ReleaseError("The app needs this team's Developer ID signature, hardened runtime, and timestamp.")
    for binary in (app / "Contents/MacOS/GlassyHost", app / "Contents/Frameworks/Sparkle.framework/Sparkle"):
        run.run(["xcrun", "lipo", binary, "-verify_arch", "arm64", "x86_64"], "Verify universal architectures")


@contextlib.contextmanager
def signing_environment(credentials, run, identity):
    p12 = credentials.get("codesign-p12", ["CODESIGN_P12_BASE64"], required=False)
    env = clean_environment()
    env["GLASSY_HOST_CODESIGN_IDENTITY"] = identity
    if not p12:
        if credentials.ci:
            raise ReleaseError("CI builds require CODESIGN_P12_BASE64 and CODESIGN_P12_PASSWORD for unattended signing.")
        yield env
        return
    password = credentials.get("codesign-password", ["CODESIGN_P12_PASSWORD"], strip=False)
    try:
        certificate = base64.b64decode(p12, validate=True)
    except (ValueError, binascii.Error):
        raise ReleaseError("CODESIGN_P12_BASE64 is not valid base64.") from None
    with tempfile.TemporaryDirectory(prefix="glassy-signing-") as temporary:
        keychain = Path(temporary) / "signing.keychain-db"
        # Only this throwaway password enters argv, never the P12 password.
        ephemeral = secrets.token_urlsafe(32)
        try:
            run.run(["security", "create-keychain", "-p", ephemeral, keychain], "Create temporary signing keychain", sensitive=True)
            run.run(["security", "set-keychain-settings", "-lut", "21600", keychain], "Configure signing keychain", sensitive=True)
            run.run(["security", "unlock-keychain", "-p", ephemeral, keychain], "Unlock signing keychain", sensitive=True)
            import_signing_identity(certificate, password, keychain)
            run.run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                     "-s", "-k", ephemeral, keychain], "Allow unattended code signing", sensitive=True)
            env["GLASSY_HOST_KEYCHAIN"] = str(keychain)
            yield env
        finally:
            if keychain.exists():
                run.run(["security", "delete-keychain", keychain], "Remove temporary signing keychain", sensitive=True)


@contextlib.contextmanager
def notary_auth(credentials):
    profile = os.environ.get("NOTARY_KEYCHAIN_PROFILE")
    if profile:
        if credentials.ci:
            raise ReleaseError("Use a notarization API key in CI instead of a Keychain profile.")
        args = ["--keychain-profile", profile]
        if os.environ.get("NOTARY_KEYCHAIN"):
            args += ["--keychain", os.environ["NOTARY_KEYCHAIN"]]
        yield args
        return
    key_id = os.environ.get("NOTARY_KEY_ID", "")
    if not re.fullmatch(r"[A-Za-z0-9]+", key_id):
        raise ReleaseError("Set NOTARY_KEY_ID to the Apple API key ID.")
    if os.environ.get("NOTARY_KEY_PATH"):
        path = Path(os.environ["NOTARY_KEY_PATH"])
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        with os.fdopen(descriptor, "rb") as source:
            details = os.fstat(source.fileno())
            if not stat.S_ISREG(details.st_mode) or details.st_uid != os.getuid() or details.st_mode & 0o077:
                raise ReleaseError("NOTARY_KEY_PATH must be an owned private file (chmod 600).")
            data = source.read(1024 * 1024 + 1)
            if len(data) > 1024 * 1024:
                raise ReleaseError("The notarization key file is too large.")
            key = data.decode()
    else:
        key = credentials.get("notary-key", ["NOTARY_PRIVATE_KEY"], strip=False)
    if "-----BEGIN PRIVATE KEY-----" not in key or "-----END PRIVATE KEY-----" not in key:
        raise ReleaseError("The notarization key must be a PEM .p8 private key.")
    with tempfile.TemporaryDirectory(prefix="glassy-notary-") as temporary:
        key_file = Path(temporary) / "AuthKey.p8"
        write_private(key_file, key.encode())
        args = ["--key", str(key_file), "--key-id", key_id]
        if os.environ.get("NOTARY_ISSUER_ID"):
            args += ["--issuer", os.environ["NOTARY_ISSUER_ID"]]
        yield args


def notarize(state, work, run, auth, save, *, submission=None):
    if state.get("notary_status") == "Accepted":
        return
    if not state.get("notary_id"):
        # Save the submission ID before waiting so a timeout is resumable.
        output, _ = run.run(["xcrun", "notarytool", "submit", submission or work / "submission.zip", *auth,
                             "--output-format", "json", "--no-progress"], "Submit to Apple notarization", sensitive=True)
        result = json.loads(output)
        state["notary_id"] = str(uuid.UUID(result["id"]))
        save()
    output, _ = run.run(["xcrun", "notarytool", "wait", state["notary_id"], *auth,
                         "--output-format", "json", "--timeout", "20m"], "Wait for Apple notarization",
                        timeout=1260, sensitive=True, allow_failure=True)
    result = json.loads(output)
    state["notary_status"] = result.get("status")
    save()
    if state["notary_status"] != "Accepted":
        raise ReleaseError(f"Apple has not accepted this app. Submission ID: {state['notary_id']}. Inspect it with notarytool log.")


def xcode_signing_certificate(identity, run):
    if re.fullmatch(r"[A-Fa-f0-9]{40}", identity):
        return identity.upper()
    output, _ = run.run(
        ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
        "Resolve the Xcode notarization signing certificate", sensitive=True,
    )
    pattern = re.compile(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"([^"]+)"$', re.MULTILINE)
    matches = [fingerprint.upper() for fingerprint, name in pattern.findall(output.decode(errors="replace"))
               if name == identity]
    if len(matches) != 1:
        raise ReleaseError("The exact Developer ID signing certificate is unavailable for Xcode notarization.")
    return matches[0]


def xcode_notarize(state, work, config, run, save, *,
                    poll_attempts=XCODE_NOTARY_POLL_ATTEMPTS,
                    poll_interval=XCODE_NOTARY_POLL_INTERVAL,
                    max_wait=20 * 60, clock=time.monotonic, sleep=time.sleep):
    """Use Xcode's signed-in local account to upload and retrieve a notarized app."""
    if state.get("notary_status") == "Accepted":
        return
    archive_text = state.get("package_archive")
    if not archive_text:
        raise ReleaseError("The packaging receipt has no Xcode archive path; start a new release.")
    archive = Path(archive_text)
    if not archive.is_dir() or not (archive / "Info.plist").is_file():
        raise ReleaseError("The packaged Xcode archive is missing; restore it before resuming.")

    if not state.get("xcode_notary_submitted"):
        signing_certificate = xcode_signing_certificate(state["identity"], run)
        export_options = {
            "destination": "upload",
            "manageAppVersionAndBuildNumber": False,
            "method": "developer-id",
            "signingCertificate": signing_certificate,
            "signingStyle": "manual",
            "teamID": config["team_id"],
        }
        options_path = work / "ExportOptions.plist"
        write_private(options_path, plistlib.dumps(export_options, fmt=plistlib.FMT_XML))
        upload_path = work / f"xcode-notary-upload-{uuid.uuid4().hex}"
        run.run([
            "xcodebuild", "-exportArchive", "-archivePath", archive,
            "-exportPath", upload_path, "-exportOptionsPlist", options_path,
            "-allowProvisioningUpdates",
        ], "Submit archive through the signed-in Xcode account", sensitive=True, timeout=1800)
        state["xcode_notary_submitted"] = True
        state["notary_status"] = "In Progress"
        save()

    attempts = max(1, poll_attempts)
    deadline = clock() + max_wait
    for attempt in range(attempts):
        remaining = deadline - clock()
        if remaining <= 0:
            break
        export_path = work / f"xcode-notarized-{uuid.uuid4().hex}"
        _, _, status = run.run([
            "xcodebuild", "-exportNotarizedApp", "-archivePath", archive,
            "-exportPath", export_path,
        ], "Check for the notarized app from Xcode", sensitive=True,
            allow_failure=True, include_status=True, timeout=max(1, min(180, remaining)))
        if status == 0:
            entries = list(export_path.iterdir()) if export_path.is_dir() else []
            if len(entries) != 1 or entries[0].name != "Glassy Desk.app" or not entries[0].is_dir():
                raise ReleaseError("Xcode returned an unexpected notarized-app export.")
            replacement = work / ".xcode-notarized-Glassy Desk.app"
            if replacement.exists():
                shutil.rmtree(replacement)
            run.run(["ditto", entries[0], replacement], "Stage the notarized app returned by Xcode")
            validate_app(replacement, config, state, run)
            staged_app = work / "Glassy Desk.app"
            if staged_app.exists():
                shutil.rmtree(staged_app)
            os.replace(replacement, staged_app)
            state["notary_status"] = "Accepted"
            save()
            shutil.rmtree(export_path)
            return
        if export_path.exists():
            shutil.rmtree(export_path)
        remaining = deadline - clock()
        if attempt + 1 < attempts and remaining > 0:
            sleep(min(poll_interval, remaining))
    raise ReleaseError("Apple has not returned the notarized app within 20 minutes. Resume this release to continue checking.")


def finalize(state, work, config, run, sparkle_key, save):
    archive = work / f"GlassyHost-{state['version']}.zip"
    if state.get("notary_status") != "Accepted":
        raise ReleaseError("Notarization must be accepted before creating the download ZIP.")
    if state.get("sha256"):
        if not archive.is_file() or digest(archive) != state["sha256"] or archive.stat().st_size != state["length"]:
            raise ReleaseError("The recorded release ZIP is missing or changed. Refusing to publish different bytes.")
        verify_signature(archive, state["signature"], config, work, run)
        return archive
    app = work / "Glassy Desk.app"
    run.run(["xcrun", "stapler", "staple", app], "Staple notarization ticket")
    run.run(["xcrun", "stapler", "validate", app], "Validate notarization ticket")
    validate_app(app, config, state, run)
    run.run(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", app], "Verify Gatekeeper acceptance")
    partial = work / "download.partial.zip"
    partial.unlink(missing_ok=True)
    run.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, partial], "Create stapled download ZIP")
    os.replace(partial, archive)
    signer = Path(state["sparkle_tools"]) / "sign_update"
    validate_sparkle_secret(sparkle_key)
    output, _ = run.run([signer, "--ed-key-file", "-", "-p", archive], "Sign Sparkle download",
                        stdin=sparkle_key.encode(), sensitive=True)
    signature = output.decode().strip()
    try:
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError()
    except (ValueError, binascii.Error):
        raise ReleaseError("Sparkle did not return a valid Ed25519 signature.") from None
    verify_signature(archive, signature, config, work, run)
    state.update(sha256=digest(archive), length=archive.stat().st_size, signature=signature)
    save()
    return archive


def verify_signature(archive, signature, config, work, run):
    run.run(["swift", "-module-cache-path", work / "swift-module-cache",
             ROOT / "script/verify_sparkle_signature.swift", archive, signature, config["sparkle_public_key"]],
            "Verify Sparkle signature against the app's public key")


def verify_public_download(url, expected_hash, expected_size):
    try:
        with urllib.request.build_opener(SafeRedirect()).open(url, timeout=180) as response:
            actual = hashlib.sha256()
            length = 0
            for block in iter(lambda: response.read(1024 * 1024), b""):
                length += len(block)
                if length > expected_size:
                    raise ReleaseError("Published download is larger than the signed artifact.")
                actual.update(block)
    except (urllib.error.URLError, TimeoutError, OSError):
        raise ReleaseError("Could not verify the public download. Resume once it is accessible.") from None
    if length != expected_size or actual.hexdigest() != expected_hash:
        raise ReleaseError("Published download differs from the signed artifact. The appcast was not advanced.")


def publish_asset(state, archive, github, save):
    marker = f"<!-- glassy-host-release:{state['id']} -->"
    release = github.release(state["tag"])
    if release is not None and marker not in (release.get("body") or ""):
        raise ReleaseError("This GitHub release already exists and is not owned by this run. It will not be changed.")
    if release is None:
        release = github.request("POST", "releases", {
            "tag_name": state["tag"], "target_commitish": state["distribution_base"],
            "name": f"Glassy Desk {state['version']}", "body": state["notes"] + "\n\n" + marker,
            "draft": True, "prerelease": False,
        })
    state["release_id"] = release["id"]
    save()
    name = archive.name
    assets = [asset for asset in github.assets(release["id"]) if asset["name"] == name]
    if len(assets) > 1:
        raise ReleaseError("Duplicate release assets found. Refusing to replace them.")
    if assets:
        asset = assets[0]
    else:
        asset = github.request("POST", f"releases/{release['id']}/assets?name={urllib.parse.quote(name)}",
                               archive.read_bytes(), binary=True)
    if asset.get("state") != "uploaded" or asset.get("size") != state["length"]:
        raise ReleaseError("GitHub asset upload is incomplete or has conflicting bytes; no assets were overwritten.")
    contents = github.request("GET", f"releases/assets/{asset['id']}", download=True)
    if len(contents) != state["length"] or hashlib.sha256(contents).hexdigest() != state["sha256"]:
        raise ReleaseError("GitHub asset does not match the signed artifact; refusing to publish the feed.")
    state["asset_id"] = asset["id"]
    save()
    if release["draft"]:
        github.request("PATCH", f"releases/{release['id']}", {"draft": False, "make_latest": "true"})
    verify_public_download(state["download_url"], state["sha256"], state["length"])
    state["asset_published"] = True
    save()


def publish_feed(state, work, config, github, run, cloudflare_token, account_id, save):
    current, blob = github.content(config["feed_path"])
    feed = updated_feed(current, state)
    if feed != current:
        commit = github.request("PUT", f"contents/{config['feed_path']}", {
            "message": f"Publish Glassy Desk {state['version']} update feed",
            "content": base64.b64encode(feed).decode(), "sha": blob, "branch": config["branch"],
        })
        state["feed_commit"] = commit["commit"]["sha"]
    else:
        ref = github.request("GET", f"git/ref/heads/{config['branch']}")
        state["feed_commit"] = ref["object"]["sha"]
    state["feed_sha256"] = hashlib.sha256(feed).hexdigest()
    save()
    # Direct upload must contain exactly these two files, never the work directory.
    with tempfile.TemporaryDirectory(prefix="glassy-pages-") as temporary:
        site = Path(temporary)
        target = site / config["feed_path"]
        target.parent.mkdir(parents=True)
        target.write_bytes(feed)
        (site / "_headers").write_text(
            f"/{config['feed_path']}\n  Content-Type: application/rss+xml; charset=utf-8\n"
            "  Cache-Control: no-cache, max-age=0, must-revalidate, no-transform\n")
        env = clean_environment()
        env.update(CLOUDFLARE_API_TOKEN=cloudflare_token, CLOUDFLARE_ACCOUNT_ID=account_id)
        latest, _ = github.content(config["feed_path"])
        if latest != feed:
            raise ReleaseError("Another release changed the feed before deployment. Resume to reconcile it.")
        run.run(["npx", "--yes", f"--package=wrangler@{config['wrangler_version']}", "wrangler", "pages", "deploy", site,
                 "--project-name", config["pages_project"], "--branch", config["branch"],
                 "--commit-hash", state["feed_commit"], "--commit-dirty=false"],
                "Deploy the Sparkle feed to Cloudflare Pages", env=env, sensitive=True)
    # Deployment propagation is read-only and bounded. A failure remains resumable.
    for attempt in range(6):
        try:
            request = urllib.request.Request(config["feed_url"], headers={
                "Accept": "application/rss+xml",
                "Cache-Control": "no-cache",
                "User-Agent": "GlassyHost-Release/1.0",
            })
            with urllib.request.urlopen(request, timeout=30) as response:
                live = response.read(4 * 1024 * 1024 + 1)
                correct_headers = "no-cache" in response.headers.get("Cache-Control", "")
                correct_headers &= "application/rss+xml" in response.headers.get("Content-Type", "")
            if live == feed and correct_headers:
                state["complete"] = True
                save()
                return
        except (urllib.error.URLError, TimeoutError, OSError):
            pass
        if attempt < 5:
            time.sleep(5)
    raise ReleaseError("Deployment finished, but the production feed has not verified yet. Resume to retry.")


def read_config(path):
    config = json.loads(path.read_text())
    for field, pattern in {
        "repository": r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", "branch": r"[A-Za-z0-9_-]+",
        "feed_path": r"[A-Za-z0-9_-]+/appcast\.xml", "pages_project": r"[a-z0-9-]+",
        "wrangler_version": r"[0-9]+\.[0-9]+\.[0-9]+", "team_id": r"[A-Z0-9]{10}",
    }.items():
        if not re.fullmatch(pattern, config.get(field, "")):
            raise ReleaseError(f"Invalid release configuration field: {field}.")
    if config["feed_url"] != f"https://{config['pages_project']}.pages.dev/{config['feed_path']}":
        raise ReleaseError("The feed URL must match the configured production Pages project.")
    if len(base64.b64decode(config["sparkle_public_key"], validate=True)) != 32:
        raise ReleaseError("Invalid Sparkle public key.")
    return config


def execute(args):
    config = read_config(args.config)
    if getattr(args, "add_dmg", None):
        if args.resume or args.notes or args.identity or args.work_dir or args.xcode_notarization:
            raise ReleaseError("--add-dmg uses the existing receipt; do not combine it with new-release options.")
        from host_release_dmg import add_installer
        add_installer(args.add_dmg, config, dry_run=args.dry_run)
        return
    if args.resume:
        work = args.resume.resolve()
        state = json.loads((work / "state.json").read_text())
        if state.get("schema") != 1 or state["config"] != config:
            raise ReleaseError("The resume receipt uses a different release configuration or schema.")
        if args.notes or args.identity or args.work_dir or getattr(args, "xcode_notarization", False):
            raise ReleaseError("--resume cannot be combined with --notes, --identity, --work-dir, or --xcode-notarization.")
        state.setdefault("notarization_mode", "notarytool")
        if state.get("complete"):
            print(f"Already released: {state['release_url']}")
            return
        if not state.get("packaged") and not (work / "package.json").is_file() and not args.dry_run:
            raise ReleaseError("Compilation did not finish for this run. Start a new release; --resume never rebuilds source.")
    else:
        metadata = app_metadata(ROOT / "GlassyHost/Support/Info.plist", config)
        if not args.notes or not args.notes.is_file() or not args.notes.read_text().strip():
            raise ReleaseError("Provide a nonempty release notes file with --notes FILE.")
        state = {"schema": 1, "config": config, "id": str(uuid.uuid4()), "dmg_required": True, **metadata,
                 "notes": args.notes.read_text().strip(),
                 "pub_date": email.utils.format_datetime(dt.datetime.now(dt.timezone.utc)),
                 "identity": args.identity or os.environ.get("GLASSY_HOST_CODESIGN_IDENTITY") or config["identity"],
                 "notarization_mode": "xcode" if getattr(args, "xcode_notarization", False) else "notarytool"}
        state["tag"] = f"v{state['version']}"
        state["release_url"] = f"https://github.com/{config['repository']}/releases/tag/{state['tag']}"
        state["download_url"] = f"https://github.com/{config['repository']}/releases/download/{state['tag']}/GlassyHost-{state['version']}.zip"
        work = args.work_dir.resolve() if args.work_dir else ROOT / "dist" / f"publish-{state['version']}-{state['id'][:8]}"
    if state.get("notarization_mode") not in ("notarytool", "xcode"):
        raise ReleaseError("The release receipt has an unsupported notarization mode.")
    if state["notarization_mode"] == "xcode" and is_ci_environment():
        raise ReleaseError("--xcode-notarization is local-only and cannot run in CI.")
    if args.dry_run:
        print(f"Glassy Desk {state['version']} ({state['build']}) → {config['repository']}")
        notary_label = "signed-in Xcode account" if state["notarization_mode"] == "xcode" else "notarytool API key"
        print(f"Compile arm64 + x86_64 → Developer ID sign → notarize ({notary_label}) → staple → Sparkle ZIP + notarized DMG → GitHub → Pages")
        print(f"Workspace: {work}\nFeed: {config['feed_url']}")
        print("Dry run: local configuration only; no credentials, compilation, uploads, or remote checks.")
        return
    if sys.platform != "darwin":
        raise ReleaseError("Releasing requires macOS with Xcode, Python 3, and Node/npm.")
    tools = ["swift", "xcrun", "security", "npx"]
    if state["notarization_mode"] == "xcode":
        tools.append("xcodebuild")
    for tool in tools:
        if not shutil.which(tool):
            raise ReleaseError(f"Required release tool is missing: {tool}.")
    if not args.resume:
        work.mkdir(mode=0o700, parents=True, exist_ok=False)
    with (work / ".lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ReleaseError("Another process is already using this release workspace.") from None
        def save():
            write_private(work / "state.json", (json.dumps(state, indent=2) + "\n").encode())
        save()
        print(f"Release workspace: {work}", flush=True)
        print(f"After compilation, retry with: ./script/release_host.sh --resume {work}", flush=True)
        credentials = Secrets()
        github = GitHub(credentials.get("github-token", ["GH_TOKEN", "GITHUB_TOKEN"]), config)
        cloudflare = credentials.get("cloudflare-token", ["CLOUDFLARE_API_TOKEN"])
        account_id = os.environ.get("CLOUDFLARE_ACCOUNT_ID") or config.get("cloudflare_account_id", "")
        if not re.fullmatch(r"[a-fA-F0-9]{32}", account_id):
            raise ReleaseError("Set CLOUDFLARE_ACCOUNT_ID (public metadata) or cloudflare_account_id in the config.")
        sparkle_key = ""
        if not state.get("sha256"):
            sparkle_key = credentials.get("sparkle-key", ["SPARKLE_PRIVATE_KEY"])
            validate_sparkle_secret(sparkle_key)
        feed, _ = github.content(config["feed_path"])
        check_feed(feed, state, allow_existing=bool(state.get("signature")))
        existing = github.release(state["tag"])
        if existing and f"<!-- glassy-host-release:{state['id']} -->" not in (existing.get("body") or ""):
            raise ReleaseError("This version already has a GitHub release. Bump the host version and build before releasing.")
        if not state.get("distribution_base"):
            ref = github.request("GET", f"git/ref/heads/{config['branch']}")
            state["distribution_base"] = ref["object"]["sha"]
            save()
        run = Runner(work)
        uses_xcode_notary = state["notarization_mode"] == "xcode"
        auth_context = (notary_auth(credentials)
                        if not uses_xcode_notary and state.get("notary_status") != "Accepted"
                        else contextlib.nullcontext([]))
        with auth_context as auth:
            if not state.get("packaged"):
                manifest = work / "package.json"
                if not manifest.exists():
                    with signing_environment(credentials, run, state["identity"]) as env:
                        run.run(["bash", ROOT / "script/package_host_release.sh", "--output-manifest", manifest],
                                "Compile and Developer ID-sign Glassy Desk (arm64 + x86_64)", env=env)
                package = json.loads(manifest.read_text())
                source_app = Path(package["app"])
                validate_app(source_app, config, state, run)
                app = work / "Glassy Desk.app"
                if app.exists():
                    shutil.rmtree(app)
                run.run(["ditto", source_app, app], "Stage app for notarization")
                shutil.copyfile(package["submission_zip"], work / "submission.zip")
                package_archive = package.get("archive")
                if uses_xcode_notary and not package_archive:
                    raise ReleaseError("The packaging manifest has no Xcode archive path.")
                state.update(packaged=True, sparkle_tools=package["sparkle_tools"],
                             submission_sha256=digest(work / "submission.zip"))
                if package_archive:
                    state["package_archive"] = str(Path(package_archive).resolve())
                save()
            if not state.get("sha256"):
                validate_app(work / "Glassy Desk.app", config, state, run)
                if uses_xcode_notary:
                    xcode_notarize(state, work, config, run, save)
                else:
                    if digest(work / "submission.zip") != state["submission_sha256"]:
                        raise ReleaseError("The notarization submission ZIP changed since packaging.")
                    notarize(state, work, run, auth, save)
        archive = finalize(state, work, config, run, sparkle_key, save)
        if state.get("dmg_required"):
            from host_release_dmg import prepare as prepare_dmg, publish as publish_dmg
            dmg, dmg_state = prepare_dmg(state, work, config, credentials)
        # Recheck immediately before publication in case another release advanced the feed.
        feed, _ = github.content(config["feed_path"])
        check_feed(feed, state, allow_existing=True)
        publish_asset(state, archive, github, save)
        if state.get("dmg_required"):
            publish_dmg(state, dmg, dmg_state, github)
        publish_feed(state, work, config, github, run, cloudflare, account_id, save)
        print(f"Released Glassy Desk {state['version']} ({state['build']}): {state['release_url']}")
        print(f"Verified production feed: {config['feed_url']}")


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv and argv[0] == "credentials":
        from host_release_credentials import main as credentials_main
        return credentials_main(argv[1:])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--notes", type=Path, help="Release notes file; required for a new release")
    parser.add_argument("--identity", help="Developer ID Application name or SHA-1")
    parser.add_argument("--work-dir", type=Path, help="New directory for artifacts and resumable state")
    parser.add_argument("--resume", type=Path, help="Continue an existing release without rebuilding")
    parser.add_argument("--add-dmg", type=Path, help="Add a notarized DMG to an existing release receipt")
    parser.add_argument("--dry-run", action="store_true", help="Inspect the local release plan without side effects")
    parser.add_argument("--xcode-notarization", action="store_true",
                        help="Local only: notarize through the developer account signed into Xcode")
    parser.add_argument("--config", type=Path, default=ROOT / "script/host-release.json")
    args = parser.parse_args(argv)
    try:
        execute(args)
    except (ReleaseError, CredentialError) as error:
        print(f"Release stopped: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError):
        # Never expose arbitrary data from malformed credential/tool responses.
        print("Release stopped: an input, saved receipt, or tool response was invalid. Check files and resume.", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Release interrupted. Use --resume with the printed workspace to continue.", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    # Installer helpers share these error types and utilities when this module
    # is launched as a script as well as when tests import it.
    sys.modules.setdefault("release_host", sys.modules[__name__])
    sys.exit(main())
