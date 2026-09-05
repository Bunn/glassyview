"""Signed, notarized first-install DMGs; the Sparkle ZIP stays immutable."""
from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import tempfile
import urllib.parse

import release_host as release


def validate_contents(dmg, config, parent, run):
    with tempfile.TemporaryDirectory(prefix="glassy-installer-check-") as temporary:
        mount = Path(temporary) / "volume"
        run.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                 "-mountpoint", mount, dmg], "Mount installer for verification")
        try:
            visible = {item.name for item in mount.iterdir() if not item.name.startswith(".")}
            if visible != {"Glassy Desk.app", "Applications"}:
                raise release.ReleaseError("The installer has unexpected visible contents.")
            applications = mount / "Applications"
            if not applications.is_symlink() or os.readlink(applications) != "/Applications":
                raise release.ReleaseError("The installer needs the Applications folder shortcut.")
            app = mount / "Glassy Desk.app"
            release.validate_app(app, config, parent, run)
            run.run(["xcrun", "stapler", "validate", app], "Validate the installed app's ticket")
        finally:
            run.run(["hdiutil", "detach", mount], "Eject installer verification volume")


def validate_dmg(dmg, config, parent, run):
    run.run(["/usr/bin/codesign", "--verify", "--strict", dmg], "Verify installer signature")
    _, details = run.run(["/usr/bin/codesign", "-d", "--verbose=4", dmg], "Inspect installer signing identity")
    text = details.decode(errors="replace")
    if (f"TeamIdentifier={config['team_id']}\n" not in text or
            "Authority=Developer ID Application:" not in text or
            not re.search(r"^Timestamp=(?!none\s*$).+", text, re.MULTILINE)):
        raise release.ReleaseError("The installer needs this team's timestamped Developer ID signature.")
    run.run(["xcrun", "stapler", "validate", dmg], "Validate the installer's own notarization ticket")
    run.run(["/usr/sbin/spctl", "--assess", "--type", "open", "--context",
             "context:primary-signature", "--verbose=2", dmg], "Verify installer Gatekeeper acceptance")
    validate_contents(dmg, config, parent, run)


def prepare_xcode_archive(state, work, parent, submission, run, env, save):
    if state.get("package_archive"):
        return
    source = Path(parent.get("package_archive", "")) / "Info.plist"
    if not source.is_file():
        raise release.ReleaseError("Restore the original Xcode archive before notarizing the installer.")
    # Xcode accepts app archives. Submit the signed DMG as an ordinary resource
    # in a private app wrapper so Apple's scanner also issues a ticket for it.
    # Only the DMG is distributed; the wrapper never becomes a release artifact.
    archive = work / "InstallerNotarization.xcarchive"
    if archive.exists():
        shutil.rmtree(archive)
    applications = archive / "Products/Applications"
    applications.mkdir(parents=True)
    run.run(["ditto", "-x", "-k", work.parent / f"GlassyHost-{parent['version']}.zip", applications],
            "Stage the app for Xcode's installer notarization submission", env=env)
    info = plistlib.loads(source.read_bytes())
    info.pop("Distributions", None)
    release.write_private(archive / "Info.plist", plistlib.dumps(info))
    wrapper = applications / "Glassy Desk.app"
    resources = wrapper / "Contents/Resources/Distribution"
    resources.mkdir()
    # copyfile keeps the signed bytes without FinderInfo xattrs, which are not
    # permitted on resources inside a signed app bundle.
    shutil.copyfile(submission, resources / f"GlassyDesk-{parent['version']}.dmg")
    command = ["/usr/bin/codesign", "--force", "--sign", parent["identity"], "--timestamp",
               "--options", "runtime", "--preserve-metadata=identifier,entitlements,requirements"]
    if env.get("GLASSY_HOST_KEYCHAIN"):
        command += ["--keychain", env["GLASSY_HOST_KEYCHAIN"]]
    run.run([*command, wrapper], "Sign the private Xcode submission wrapper", env=env)
    state["package_archive"] = str(archive)
    save()


def prepare(parent, release_work, config, credentials):
    """Build once, resume notarization, and verify the actual image and contents."""
    source_zip = release_work / f"GlassyHost-{parent['version']}.zip"
    if (parent.get("notary_status") != "Accepted" or not source_zip.is_file() or
            release.digest(source_zip) != parent.get("sha256") or
            source_zip.stat().st_size != parent.get("length")):
        raise release.ReleaseError("The original verified release ZIP is missing or changed.")
    mode = parent.get("notarization_mode", "notarytool")
    if mode not in ("notarytool", "xcode") or (mode == "xcode" and release.is_ci_environment()):
        raise release.ReleaseError("Xcode installer notarization is local-only; use notarytool in CI.")
    work = release_work / "dmg"
    work.mkdir(mode=0o700, exist_ok=True)
    receipt = work / "state.json"
    identity = {"schema": 1, "parent_id": parent["id"], "source_sha256": parent["sha256"],
                "config": config, "notarization_mode": mode}
    if receipt.exists():
        state = json.loads(receipt.read_text())
        if any(state.get(key) != value for key, value in identity.items()):
            raise release.ReleaseError("The installer receipt belongs to a different release.")
    else:
        state = {**identity, **{key: parent[key] for key in
                               ("version", "build", "minimum_system", "identity")}}

    def save():
        release.write_private(receipt, (json.dumps(state, indent=2) + "\n").encode())

    save()
    run = release.Runner(work)
    submission = work / "submission.dmg"
    dmg = work / f"GlassyDesk-{parent['version']}.dmg"
    if state.get("sha256"):
        if (not dmg.is_file() or release.digest(dmg) != state["sha256"] or
                dmg.stat().st_size != state["length"]):
            raise release.ReleaseError("The recorded installer is missing or changed; refusing different bytes.")
        validate_dmg(dmg, config, parent, run)
        return dmg, state
    if state.get("signed_sha256"):
        if not submission.is_file() or release.digest(submission) != state["signed_sha256"]:
            raise release.ReleaseError("The installer notarization submission changed; restore its original bytes.")
    else:
        python = Path(os.environ.get("GLASSY_DMG_PYTHON", str(release.ROOT / ".build/dmgbuild/bin/python")))
        if not python.is_file():
            raise release.ReleaseError("Install script/dmg/requirements.txt in .build/dmgbuild, or set GLASSY_DMG_PYTHON.")
        with tempfile.TemporaryDirectory(prefix="build-", dir=work) as temporary:
            staging = Path(temporary)
            run.run(["ditto", "-x", "-k", source_zip, staging], "Extract the immutable Sparkle app for the installer")
            app = staging / "Glassy Desk.app"
            release.validate_app(app, config, parent, run)
            partial = staging / "installer.dmg"
            run.run([python, release.ROOT / "script/build_host_dmg.py", "--app", app, "--output", partial],
                    "Build the Glassy Desk welcome window")
            validate_contents(partial, config, parent, run)
            with release.signing_environment(credentials, run, parent["identity"]) as env:
                command = ["/usr/bin/codesign", "--sign", parent["identity"], "--timestamp"]
                if env.get("GLASSY_HOST_KEYCHAIN"):
                    command += ["--keychain", env["GLASSY_HOST_KEYCHAIN"]]
                run.run([*command, partial], "Sign the installer disk image", env=env)
            os.replace(partial, submission)
        state["signed_sha256"] = release.digest(submission)
        save()
    if state.get("notary_status") != "Accepted":
        if mode == "xcode":
            with release.signing_environment(credentials, run, parent["identity"]) as env:
                prepare_xcode_archive(state, work, parent, submission, run, env, save)
                release.xcode_notarize(state, work, config, run, save)
        else:
            with release.notary_auth(credentials) as auth:
                release.notarize(state, work, run, auth, save, submission=submission)
    # Keep the submitted bytes immutable. An interrupted staple can be retried
    # from this copy without re-signing or submitting different code to Apple.
    shutil.copyfile(submission, dmg)
    os.chmod(dmg, 0o600)
    run.run(["xcrun", "stapler", "staple", dmg], "Staple the disk image's own notarization ticket")
    validate_dmg(dmg, config, parent, run)
    state.update(sha256=release.digest(dmg), length=dmg.stat().st_size)
    save()
    return dmg, state


def publish(parent, dmg, state, github):
    # Reuse the established ownership, immutable upload, and public-byte checks.
    if release.digest(dmg) != state["sha256"] or dmg.stat().st_size != state["length"]:
        raise release.ReleaseError("The verified installer changed before publication.")
    artifact = {**parent, **{key: state[key] for key in ("sha256", "length")}}
    artifact["download_url"] = (f"https://github.com/{parent['config']['repository']}/releases/download/"
                                f"{parent['tag']}/{urllib.parse.quote(dmg.name)}")

    def save():
        for key in ("asset_id", "asset_published", "download_url", "release_id"):
            if key in artifact:
                state[key] = artifact[key]
        release.write_private(dmg.parent / "state.json", (json.dumps(state, indent=2) + "\n").encode())

    # The ZIP's published marker is not evidence that this additional asset is
    # published. Reconcile the remote asset on every retry.
    artifact.pop("asset_published", None)
    artifact.pop("asset_id", None)
    release.publish_asset(artifact, dmg, github, save)
    state["complete"] = True
    save()
    print(f"Verified DMG installer: {artifact['download_url']}", flush=True)


def add_installer(release_work, config, *, dry_run=False):
    release_work = release_work.resolve()
    parent = json.loads((release_work / "state.json").read_text())
    if parent.get("schema") != 1 or parent.get("config") != config or not parent.get("asset_published"):
        raise release.ReleaseError("Choose the receipt for an already published release with the same configuration.")
    if dry_run:
        print(f"Add GlassyDesk-{parent['version']}.dmg using the existing {parent.get('notarization_mode', 'notarytool')} flow.")
        print("Dry run: no credentials, packaging, uploads, or changes to the ZIP or appcast.")
        return
    with (release_work / ".lock").open("a") as lock:
        try:
            release.fcntl.flock(lock, release.fcntl.LOCK_EX | release.fcntl.LOCK_NB)
        except BlockingIOError:
            raise release.ReleaseError("Another process is using this release workspace.") from None
        credentials = release.Secrets()
        github = release.GitHub(credentials.get("github-token", ["GH_TOKEN", "GITHUB_TOKEN"]), config)
        remote = github.release(parent["tag"])
        if remote is None or f"<!-- glassy-host-release:{parent['id']} -->" not in (remote.get("body") or ""):
            raise release.ReleaseError("The published release does not belong to this receipt.")
        dmg, state = prepare(parent, release_work, config, credentials)
        publish(parent, dmg, state, github)
