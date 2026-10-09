#!/usr/bin/env python3
"""Compose iPhone Duo App Store screenshots (2007 x 2853, APP_IPHONE_DUO).

Uses the dark "short bold headline" style that won the September 2026 product
page experiment. Inputs are inner-display captures from
`simctl io <device> screenshot` of a real folded session; device3d.py places
them on a 3D model of the Duo. The only change to app pixels is blanking the
free-session countdown, which subscribers never see.

    python3 compose.py
"""
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont, ImageStat

import device3d

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
RAW = os.path.join(HERE, "raw")
OUT = os.path.join(HERE, "en-US", "duo")
ICON = os.path.join(REPO, "dejaview/Assets.xcassets/AppIcon.appiconset/Icon-Dark.png")
SF = "/System/Library/Fonts/SFNS.ttf"

W, H = 2007, 2853
MARGIN = 140
NAVY_TOP, NAVY_BOTTOM = (4, 9, 28), (8, 22, 66)
BLUE = (34, 156, 255)
WHITE = (255, 255, 255)

# Each image: capture, headline lines, subtitle, and the camera on the device.
SHOTS = [
    dict(out="01-half-fold-laptop.png", capture="half-fold-trackpad.png",
         lines=("Fold it.", "It's a laptop."),
         subtitle="Half-fold iPhone Duo. The bottom becomes a trackpad.",
         camera=dict(fold_deg=90, yaw=-24, pitch=24)),
    dict(out="02-trackpad.png", capture="half-fold-trackpad.png",
         lines=("Point. Scroll.", "Right-click."),
         subtitle="One finger moves. Two fingers scroll or right-click.",
         camera=dict(fold_deg=90, yaw=26, pitch=38), touches=True),
    dict(out="03-keyboard.png", capture="half-fold-keyboard.png",
         lines=("Type.", "Like a laptop."),
         subtitle="Keyboard and special keys fold out below your Mac.",
         camera=dict(fold_deg=90, yaw=-14, pitch=30),
         # Countdown pill over the desktop in this capture (below the toolbar).
         desktop_timer=(1715, 178, 2007, 330)),
]


def font(size, weight):
    f = ImageFont.truetype(SF, size)
    f.set_variation_by_name(weight)
    return f


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def background():
    bg = Image.new("RGB", (W, H))
    px = ImageDraw.Draw(bg)
    for y in range(H):
        px.line([(0, y), (W, y)], fill=lerp(NAVY_TOP, NAVY_BOTTOM, y / H))
    # Electric-blue light arcs, blurred into a soft glow like the iPhone set.
    glow = Image.new("RGB", (W, H))
    g = ImageDraw.Draw(glow)
    g.ellipse([-1400, 1150, 2900, 5200], outline=(30, 120, 255), width=22)
    g.ellipse([700, -900, 3700, 2000], outline=(40, 140, 255), width=14)
    glow = Image.blend(glow.filter(ImageFilter.GaussianBlur(70)),
                       glow.filter(ImageFilter.GaussianBlur(8)), 0.35)
    return ImageChops.add(bg, glow)


def header(canvas, lines, subtitle):
    d = ImageDraw.Draw(canvas)
    icon = Image.open(ICON).convert("RGBA").resize((120, 120), Image.LANCZOS)
    mask = Image.new("L", icon.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, 119, 119], 27, fill=255)
    canvas.paste(icon, (MARGIN, 130), mask)
    d.text((MARGIN + 150, 190), "Glassy Desk", font=font(66, "Semibold"), fill=WHITE, anchor="lm")

    size = 210
    big = font(size, "Heavy")
    while max(d.textlength(t, font=big) for t in lines) > W - 2 * MARGIN:
        size -= 6
        big = font(size, "Heavy")
    y = 360
    for text, color in zip(lines, (WHITE, BLUE)):
        d.text((MARGIN - 6, y), text, font=big, fill=color)
        y += round(size * 1.02)
    d.text((MARGIN, y + 40), subtitle, font=font(64, "Regular"), fill=(214, 226, 255))
    return y + 150


def fold_line(capture):
    """The Duo inner display folds at its midpoint."""
    return capture.height // 2


def hide_free_timer(capture):
    """Blank the free-session countdown pill under the folded toolbar.

    Subscribers never see it. The pane behind it is pure black, so filling the
    pill's bounding box with black is the only change made to app pixels.
    """
    gray = capture.convert("L")
    x0, y0, x1, y1 = 1500, fold_line(capture) + 60, capture.width, capture.height
    # Lit row bands on the trailing side: toolbar, timer pill, then the trackpad.
    bands, start = [], None
    for y in range(y0, y1):
        lit = gray.crop((x0, y, x1, y + 1)).getextrema()[1] > 3
        if lit and start is None:
            start = y
        elif not lit and start is not None:
            bands.append((start, y)); start = None
    if len(bands) >= 3 and bands[1][1] - bands[1][0] < 200:
        top, bottom = bands[1]
        ImageDraw.Draw(capture).rectangle([x0, top - 4, x1, bottom + 4], fill=(0, 0, 0))
    return capture


def restore_desktop(capture, box):
    """Replace box with the remote desktop the session was showing.

    With the keyboard up, the toolbar and countdown move over the desktop.
    The desktop is raw/mac-desktop.png, served unchanged by the mock VNC host
    and drawn full-width; locate it by best match, then paste the same pixels
    back under the countdown.
    """
    src = Image.open(os.path.join(RAW, "mac-desktop.png")).convert("RGB")
    scaled = src.resize((capture.width, round(src.height * capture.width / src.width)), Image.LANCZOS)
    probe = scaled.crop((0, 400, 1400, 700))

    def mismatch(top):
        return sum(ImageStat.Stat(ImageChops.difference(
            capture.crop((0, top + 400, 1400, top + 700)), probe)).mean)

    top = min(range(0, capture.height // 2 - scaled.height), key=mismatch)
    x0, y0, x1, y1 = box
    capture.paste(scaled.crop((x0, y0 - top, x1, y1 - top)), (x0, y0))
    return capture


def add_touches(capture):
    """Two touch points in the trackpad's empty lower area, below its label.

    Drawn on the capture so they follow the device's perspective; they show
    the gesture without covering app UI.
    """
    glow = Image.new("RGBA", capture.size, (0, 0, 0, 0))
    dots = Image.new("RGBA", capture.size, (0, 0, 0, 0))
    gd, dd = ImageDraw.Draw(glow), ImageDraw.Draw(dots)
    cy = round(capture.height * 0.915)
    for cx in (capture.width // 2 - 110, capture.width // 2 + 110):
        gd.ellipse([cx - 95, cy - 95, cx + 95, cy + 95], fill=BLUE + (210,))
        dd.ellipse([cx - 60, cy - 60, cx + 60, cy + 60], fill=(255, 255, 255, 120),
                   outline=(255, 255, 255, 235), width=6)
    out = capture.convert("RGBA")
    out.alpha_composite(glow.filter(ImageFilter.GaussianBlur(30)))
    out.alpha_composite(dots.filter(ImageFilter.GaussianBlur(1)))
    return out.convert("RGB")


def main():
    os.makedirs(OUT, exist_ok=True)
    only = sys.argv[1:]
    for shot in SHOTS:
        if only and not any(o in shot["out"] for o in only):
            continue
        path = os.path.join(RAW, shot["capture"])
        if not os.path.exists(path):
            print(f"skipping {shot['out']}: no {shot['capture']} yet")
            continue
        capture = hide_free_timer(Image.open(path).convert("RGB"))
        if capture.size != (W, H):
            sys.exit(f"{path}: expected {W}x{H} inner-display capture, got {capture.size}")
        if shot.get("desktop_timer"):
            capture = restore_desktop(capture, shot["desktop_timer"])
        if shot.get("touches"):
            capture = add_touches(capture)
        canvas = background().convert("RGBA")
        top = header(canvas, shot["lines"], shot["subtitle"])
        device3d.render(capture, canvas, (70, top + 20, W - 70, H - 70), **shot["camera"])
        dest = os.path.join(OUT, shot["out"])
        canvas.convert("RGB").save(dest, optimize=True)
        print(dest)


if __name__ == "__main__":
    main()
