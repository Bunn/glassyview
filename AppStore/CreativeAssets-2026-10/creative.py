#!/usr/bin/env python3
"""Compose the App Store creative assets for Glassy Desk (October 2026).

Two images, in the same dark navy look as the screenshots next door:

    header.png          3840 x 1646  product page header (no text to translate)
    search-results.png  3840 x 2560  search results asset (headline from copy.json)

    python3 creative.py                  # en-US
    python3 creative.py --locale de-DE   # one other locale
    python3 creative.py --locale all     # every locale in copy.json

en-US is written to en-US/, which is committed. Every other locale goes to
build/<locale>/, which git ignores. Device captures and device drawing are
shared with ../Screenshots-2026-10/compose.py.
"""
import argparse
import json
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "Screenshots-2026-10"))
import compose as shots  # noqa: E402

HEADER_SIZE = (3840, 1646)
SEARCH_SIZE = (3840, 2560)
SOURCE_LOCALE = shots.SOURCE_LOCALE
WHITE = (255, 255, 255)


def glow(canvas, center, radius, strength):
    """A soft blue light on the background, strongest at center."""
    mask = Image.new("L", canvas.size, 0)
    ImageDraw.Draw(mask).ellipse((center[0] - radius, center[1] - radius, center[0] + radius, center[1] + radius),
                                 fill=round(255 * strength))
    canvas.paste(Image.new("RGB", canvas.size, shots.GLOW), (0, 0), mask.filter(ImageFilter.GaussianBlur(radius // 2)))


def panes(size):
    """The two glass panes from the app icon, rendered from its vector layers (see README.md)."""
    art = Image.open(os.path.join(HERE, "art", "pane-back.png")).convert("RGBA")
    art.alpha_composite(Image.open(os.path.join(HERE, "art", "pane-front.png")).convert("RGBA"))
    return art.resize((size, size), Image.LANCZOS)


def faded(image, opacity):
    faint = image.copy()
    faint.putalpha(image.getchannel("A").point(lambda value: round(value * opacity)))
    return faint


def header():
    """The brand, centered: the icon's panes above the name.

    iPhone shows only the middle of this image, with the status bar and buttons over
    the top, so everything that matters sits in the center and below the top quarter.
    The large faint panes at the sides are decoration that may be cropped.
    """
    width, height = HEADER_SIZE
    canvas = shots.background(HEADER_SIZE)
    glow(canvas, (width // 2, round(height * 0.52)), 1050, 0.5)

    echo = faded(panes(1900), 0.13).filter(ImageFilter.GaussianBlur(5))
    for center_x in (round(width * 0.105), round(width * 0.895)):
        canvas.paste(echo, (center_x - echo.width // 2, round(height * 0.5) - echo.height // 2), echo)

    mark = panes(800)
    left, top = (width - mark.width) // 2, round(height * 0.445) - mark.height // 2
    shadow = Image.new("L", canvas.size, 0)
    shadow.paste(mark.getchannel("A"), (left, top + 36))
    shadow = shadow.filter(ImageFilter.GaussianBlur(40)).point(lambda value: round(value * 0.55))
    canvas.paste(Image.new("RGB", canvas.size, (0, 2, 20)), (0, 0), shadow)
    canvas.paste(mark, (left, top), mark)

    ImageDraw.Draw(canvas).text((width / 2, round(height * 0.775)), "Glassy Desk",
                                font=shots.headline_font(SOURCE_LOCALE, 230), fill=WHITE, anchor="mm")
    return canvas


def search_results(locale, text):
    """What the app does, at a glance: one line, and the Mac on an iPad and an iPhone."""
    width, height = SEARCH_SIZE
    canvas = shots.background(SEARCH_SIZE)
    glow(canvas, (width // 2, round(height * 0.62)), 1500, 0.5)

    margin = round(width * 0.09)
    size = 300
    while shots.headline_font(locale, size).getlength(text) > width - 2 * margin:
        size -= 4
    ImageDraw.Draw(canvas).text((width / 2, round(height * 0.155)), text,
                                font=shots.headline_font(locale, size), fill=WHITE, anchor="mm")

    ipad = shots.framed(shots.prepare("ipad-landscape.png", "ipad"), "ipad")
    iphone = shots.framed(shots.prepare("iphone-landscape.png", "iphone"), "iphone")
    ipad_width = 2180
    ipad_height = ipad_width * ipad.height / ipad.width
    shots.place(canvas, ipad, (width * 0.44, height * 0.295 + ipad_height / 2), ipad_width)
    shots.place(canvas, iphone, (width * 0.68, height * 0.775), 1560, angle=5)
    return canvas


def save(image, locale, name):
    folder = locale if locale == SOURCE_LOCALE else os.path.join("build", locale)
    os.makedirs(os.path.join(HERE, folder), exist_ok=True)
    image.save(os.path.join(HERE, folder, name), optimize=True)
    print("wrote", os.path.join(folder, name))


def main():
    with open(os.path.join(HERE, "copy.json"), encoding="utf-8") as file:
        copy = json.load(file)
    parser = argparse.ArgumentParser(description="Compose the App Store creative assets.")
    parser.add_argument("--locale", default=SOURCE_LOCALE, choices=sorted(copy) + ["all"],
                        help="a locale from copy.json, or all (default: %(default)s)")
    args = parser.parse_args()
    brand = header()
    for locale in sorted(copy) if args.locale == "all" else [args.locale]:
        save(brand, locale, "header.png")
        save(search_results(locale, copy[locale]["search"]), locale, "search-results.png")


if __name__ == "__main__":
    main()
