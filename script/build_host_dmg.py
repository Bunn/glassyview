#!/usr/bin/env python3
"""Build the Finder installation window. The release pipeline signs and notarizes it."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import tempfile

import dmgbuild

ROOT = Path(__file__).resolve().parent.parent


def build(app: Path, output: Path):
    app = app.resolve(strict=True)
    output = output.absolute()
    if app.name != "Glassy Desk.app" or not (app / "Contents/Info.plist").is_file():
        raise ValueError("Choose the packaged Glassy Desk.app bundle.")
    if output.suffix != ".dmg" or output.exists() or output.is_symlink():
        raise ValueError("The DMG must be a new file; existing artifacts are never replaced.")
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], check=True)
    subprocess.run(["xcrun", "stapler", "validate", app], check=True)
    with tempfile.TemporaryDirectory(prefix="glassy-dmg-") as temporary:
        artwork = Path(temporary)
        subprocess.run(["swift", ROOT / "script/dmg/render_background.swift", artwork], check=True)
        dmgbuild.build_dmg(str(output), "Glassy Desk", settings={
            "format": "ULFO",
            "filesystem": "HFS+",
            "files": [str(app)],
            "symlinks": {"Applications": "/Applications"},
            "icon": str(app / "Contents/Resources/GlassyDeskAppIcon.icns"),
            # Setting FinderInfo on the app to hide its extension invalidates
            # strict code-signing validation. Respect Finder's display setting.
            "hide_extensions": [],
            "background": str(artwork / "background.tiff"),
            "window_rect": ((180, 180), (700, 540)),
            "default_view": "icon-view",
            "show_status_bar": False,
            "show_tab_view": False,
            "show_toolbar": False,
            "show_pathbar": False,
            "show_sidebar": False,
            "show_icon_preview": False,
            "include_icon_view_settings": True,
            "include_list_view_settings": False,
            "arrange_by": None,
            "grid_spacing": 80,
            "icon_size": 104,
            "text_size": 14,
            "label_pos": "bottom",
            "icon_locations": {"Glassy Desk.app": (173, 250), "Applications": (527, 250)},
        })
    os.chmod(output, 0o600)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    build(args.app, args.output)
