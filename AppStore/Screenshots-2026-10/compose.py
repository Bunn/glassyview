#!/usr/bin/env python3
"""Compose the iPhone and iPad App Store screenshots (October 2026).

Every image uses the same recipe: dark navy background, one headline line,
and the device as the subject. Inputs are simulator captures in raw/ (see
README.md for how they were taken and what was retouched). Headlines come
from copy.json, one block per App Store locale.

    python3 compose.py                    # en-US, everything
    python3 compose.py iphone 02          # en-US, one image
    python3 compose.py --locale de-DE     # one other locale
    python3 compose.py --locale all       # every locale in copy.json

en-US is written to en-US/, which is committed. Every other locale goes to
build/<locale>/, which git ignores.
"""
import argparse
import json
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "raw")
SF = "/System/Library/Fonts/SFNS.ttf"
# Headline fonts for locales SF has no glyphs for: (path, face index).
LOCALE_FONTS = {
    "ja": ("/System/Library/Fonts/ヒラギノ角ゴシック W7.ttc", 0),
    "zh-Hans": ("/System/Library/Fonts/Hiragino Sans GB.ttc", 2),
}
SOURCE_LOCALE = "en-US"

NAVY_TOP, NAVY_BOTTOM = (3, 7, 22), (7, 20, 60)
GLOW = (28, 120, 255)
WHITE = (255, 255, 255)

# Canvas, simulator scale, and device hardware (in screenshot pixels).
DEVICES = {
    "iphone": dict(size=(1320, 2868), scale=3,
                   corner=186, bezel=34, rim=7, island=(378, 111, 42)),
    "ipad": dict(size=(2064, 2752), scale=2,
                 corner=50, bezel=62, rim=7, island=None),
}

SHOTS = {
    "iphone": [
        dict(out="01-your-mac.png", layout="hero",
             back="iphone-hosts.png", front="iphone-landscape.png"),
        dict(out="02-hosts.png", capture="iphone-hosts.png"),
        dict(out="03-keyboard.png", capture="iphone-keyboard.png"),
        dict(out="04-two-ways.png", capture="iphone-add-mac.png"),
        dict(out="05-picture-in-picture.png", layout="pip",
             capture="iphone-home.png"),
        dict(out="06-external-display.png", layout="external",
             capture="iphone-controller.png"),
        dict(out="07-file-transfer.png", capture="iphone-files.png"),
        dict(out="08-curtain-mode.png", layout="external",
             capture="iphone-landscape.png", display="mac-curtain.png", zoom=2.0, display_width=0.9),
    ],
    "ipad": [
        dict(out="01-your-mac.png", layout="hero",
             back="ipad-hosts.png", front="ipad-landscape.png"),
        dict(out="02-hosts.png", capture="ipad-hosts.png"),
        dict(out="03-keyboard.png", capture="ipad-keyboard.png"),
        dict(out="04-two-ways.png", capture="ipad-add-mac.png"),
        dict(out="05-picture-in-picture.png", capture="ipad-pip.png"),
        dict(out="06-external-display.png", layout="external",
             capture="ipad-controller.png"),
        dict(out="07-file-transfer.png", capture="ipad-files.png"),
        dict(out="08-curtain-mode.png", layout="external",
             capture="ipad-landscape.png", display="mac-curtain.png", zoom=1.6),
    ],
}


def headline_font(locale, size):
    if locale in LOCALE_FONTS:
        path, index = LOCALE_FONTS[locale]
        return ImageFont.truetype(path, size, index=index)
    f = ImageFont.truetype(SF, size)
    f.set_variation_by_name("Bold")
    return f


def load_copy():
    with open(os.path.join(HERE, "copy.json"), encoding="utf-8") as file:
        return json.load(file)


def headline_text(copy, locale, device, shot):
    """The headline for a shot, keyed in copy.json by its two-digit number."""
    text = copy[locale][shot["out"][:2]]
    return text[device] if isinstance(text, dict) else text


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


# --- Retouching -----------------------------------------------------------

def prepare(name, device):
    """Load a capture and apply the retouches documented in README.md."""
    image = Image.open(os.path.join(RAW, name)).convert("RGB")
    scale = DEVICES[device]["scale"]
    draw = ImageDraw.Draw(image)

    def blank(box):  # the free-session countdown, which subscribers never see
        draw.rectangle(tuple(round(v * scale) for v in box), fill=(0, 0, 0))

    if name in ("iphone-keyboard.png", "iphone-controller.png", "iphone-files.png"):
        blank((14, 76, 112, 132))
    if name in ("ipad-landscape.png", "ipad-keyboard.png", "ipad-controller.png", "ipad-files.png"):
        blank((14, 14, 112, 70))
    if name == "iphone-landscape.png":
        # Here the countdown floats over the Mac, so put the desktop back.
        desktop = Image.open(os.path.join(RAW, "mac-desktop.png")).convert("RGB")
        desktop_width = round(image.height * desktop.width / desktop.height)
        left = (image.width - desktop_width) // 2
        desktop = desktop.resize((desktop_width, image.height), Image.LANCZOS)
        box = (round(70 * scale), round(10 * scale), round(182 * scale), round(74 * scale))
        draw.rectangle((box[0], box[1], box[2] - 1, box[3] - 1), fill=(0, 0, 0))
        image.paste(desktop.crop((0, box[1], box[2] - left, box[3])), (left, box[1]))
    return image


def with_pip(screen, device):
    """Draw a Picture in Picture window showing the Mac over a Home Screen capture.

    The iPhone simulator has no Picture in Picture, so this stands in for it. Proportions,
    corner, and placement follow the real window in ipad-pip.png.
    """
    scale = DEVICES[device]["scale"]
    desktop = Image.open(os.path.join(RAW, "mac-desktop.png")).convert("RGB")
    width = round(300 * scale)
    size = (width, round(width * desktop.height / desktop.width))
    left = screen.width - size[0] - round(16 * scale)
    top = round(756 * scale) - size[1]

    shadow = Image.new("L", screen.size, 0)
    ImageDraw.Draw(shadow).rounded_rectangle((left, top + 6 * scale, left + size[0], top + size[1] + 6 * scale),
                                             22 * scale, fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(14 * scale))
    screen.paste(Image.new("RGB", screen.size, (0, 0, 0)), (0, 0), shadow)
    screen.paste(desktop.resize(size, Image.LANCZOS), (left, top), rounded_mask(size, 22 * scale))
    return screen


# --- Device ---------------------------------------------------------------

def rounded_mask(size, radius, supersample=3):
    big = Image.new("L", (size[0] * supersample, size[1] * supersample), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, big.width - 1, big.height - 1), radius * supersample, fill=255)
    return big.resize(size, Image.LANCZOS)


def framed(screen, device):
    """Put a capture inside a simple dark device body. Landscape captures get a landscape body."""
    spec = DEVICES[device]
    bezel, rim, corner = spec["bezel"], spec["rim"], spec["corner"]
    pad = bezel + rim
    body_size = (screen.width + 2 * pad, screen.height + 2 * pad)
    body = Image.new("RGBA", body_size, (0, 0, 0, 0))

    # Rim: a soft vertical metal gradient, then the black bezel inside it.
    metal = Image.new("RGB", body_size)
    metal_draw = ImageDraw.Draw(metal)
    for y in range(body_size[1]):
        t = y / (body_size[1] - 1)
        metal_draw.line([(0, y), (body_size[0], y)], fill=lerp((104, 112, 132), (38, 42, 56), t))
    body.paste(metal, (0, 0), rounded_mask(body_size, corner + pad))
    inner = (body_size[0] - 2 * rim, body_size[1] - 2 * rim)
    body.paste(Image.new("RGB", inner, (2, 2, 4)), (rim, rim), rounded_mask(inner, corner + bezel))
    body.paste(screen, (pad, pad), rounded_mask(screen.size, corner))

    if spec["island"] and screen.height > screen.width:
        width, height, top = spec["island"]
        left = pad + (screen.width - width) // 2
        ImageDraw.Draw(body).rounded_rectangle((left, pad + top, left + width, pad + top + height),
                                               height // 2, fill=(0, 0, 0, 255))
    return body


def monitor(width, showing="mac-desktop.png", zoom=1.0):
    """A display above the device: the Mac in controller mode, or the Mac's own curtained screen.

    zoom > 1 crops to the centre of the image, so the curtain's small text stays legible.
    """
    desktop = Image.open(os.path.join(RAW, showing)).convert("RGB")
    if zoom > 1:
        inset_x = round(desktop.width * (1 - 1 / zoom) / 2)
        inset_y = round(desktop.height * (1 - 1 / zoom) / 2)
        desktop = desktop.crop((inset_x, inset_y, desktop.width - inset_x, desktop.height - inset_y))
    bezel = max(8, round(width * 0.012))
    rim = max(2, bezel // 5)
    screen = desktop.resize((width - 2 * bezel, round((width - 2 * bezel) * desktop.height / desktop.width)),
                            Image.LANCZOS)
    size = (width, screen.height + 2 * bezel)
    body = Image.new("RGBA", size, (0, 0, 0, 0))
    body.paste(Image.new("RGB", size, (70, 76, 94)), (0, 0), rounded_mask(size, bezel * 2))
    inner = (size[0] - 2 * rim, size[1] - 2 * rim)
    body.paste(Image.new("RGB", inner, (16, 17, 22)), (rim, rim), rounded_mask(inner, bezel * 2 - rim))
    body.paste(screen, (bezel, bezel), rounded_mask(screen.size, bezel))
    return body


def place(canvas, device_image, center, width, angle=0.0, dim=1.0):
    """Scale, rotate, and composite a device with a glow and a contact shadow."""
    scale = width / device_image.width
    image = device_image.resize((round(width), round(device_image.height * scale)), Image.LANCZOS)
    if dim < 1:
        red, green, blue, alpha = image.split()
        darker = Image.merge("RGB", (red, green, blue)).point(lambda value: round(value * dim))
        image = Image.merge("RGBA", (*darker.split(), alpha))
    if angle:
        image = image.rotate(angle, resample=Image.BICUBIC, expand=True)
    x, y = round(center[0] - image.width / 2), round(center[1] - image.height / 2)

    alpha = image.getchannel("A")
    blur = max(canvas.size) // 14
    halo = Image.new("L", canvas.size, 0)
    halo.paste(alpha, (x, y))
    halo = halo.filter(ImageFilter.GaussianBlur(blur)).point(lambda value: round(value * 0.55))
    canvas.paste(Image.new("RGB", canvas.size, GLOW), (0, 0), halo)

    shadow = Image.new("L", canvas.size, 0)
    shadow.paste(alpha, (x, y + blur // 5))
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur // 4)).point(lambda value: round(value * 0.7))
    canvas.paste(Image.new("RGB", canvas.size, (0, 0, 6)), (0, 0), shadow)
    canvas.paste(image, (x, y), image)


# --- Page -----------------------------------------------------------------

def background(size):
    width, height = size
    column = Image.new("RGB", (1, height))
    for y in range(height):
        column.putpixel((0, y), lerp(NAVY_TOP, NAVY_BOTTOM, y / (height - 1)))
    return column.resize(size)


def headline(canvas, text, locale):
    """One centered line, as large as fits the margins. Returns its bottom edge."""
    width, height = canvas.size
    margin = round(width * 0.07)
    size = round(width * 0.105)
    while headline_font(locale, size).getlength(text) > width - 2 * margin:
        size -= 2
    chosen = headline_font(locale, size)
    top = round(height * 0.062)
    draw = ImageDraw.Draw(canvas)
    draw.text((width / 2, top), text, font=chosen, fill=WHITE, anchor="ma")
    return top + chosen.getbbox(text)[3]


def compose(device, shot, locale, text):
    spec = DEVICES[device]
    width, height = spec["size"]
    canvas = background(spec["size"])
    text_bottom = headline(canvas, text, locale)
    top = text_bottom + round(height * 0.045)
    bottom = height - round(height * 0.04)
    available = bottom - top

    if shot.get("layout") == "hero":
        back = framed(prepare(shot["back"], device), device)
        front = framed(prepare(shot["front"], device), device)
        # A dimmed Hosts list behind, the live Mac in front.
        back_width = min(width * 0.72, available * 0.86 * back.width / back.height)
        back_height = back.height * back_width / back.width
        place(canvas, back, (width * 0.5, top + back_height / 2), back_width, dim=0.5)
        front_height = front.height * width * 0.92 / front.width
        place(canvas, front, (width * 0.5, bottom - front_height * 0.62), width * 0.92, angle=5)
    elif shot.get("layout") == "external":
        # The Mac on a display above, the device below it as trackpad and keyboard.
        body = framed(prepare(shot["capture"], device), device)
        landscape = body.width > body.height
        display = monitor(round(width * shot.get("display_width", 0.8 if landscape else 0.88)),
                          shot.get("display", "mac-desktop.png"), shot.get("zoom", 1.0))
        overlap = display.height * 0.12
        device_height = available - display.height + overlap
        device_width = min(width * 0.88, device_height * body.width / body.height)
        device_height = device_width * body.height / body.width
        used = display.height - overlap + device_height
        start = top + (available - used) / 2
        place(canvas, display, (width / 2, start + display.height / 2), display.width)
        place(canvas, body, (width / 2, start + display.height - overlap + device_height / 2), device_width)
    else:
        screen = prepare(shot["capture"], device)
        if shot.get("layout") == "pip":
            screen = with_pip(screen, device)
        body = framed(screen, device)
        fit = min(width * 0.9 / body.width, available / body.height)
        if body.width > body.height:  # landscape device on a portrait page
            fit = width * 0.93 / body.width
        device_width = body.width * fit
        device_height = body.height * fit
        center_y = top + (available - device_height) * (0.5 if body.height > body.width else 0.42) + device_height / 2
        place(canvas, body, (width / 2, center_y), device_width)

    folder = os.path.join(locale, device)
    if locale != SOURCE_LOCALE:
        folder = os.path.join("build", folder)
    os.makedirs(os.path.join(HERE, folder), exist_ok=True)
    canvas.save(os.path.join(HERE, folder, shot["out"]), optimize=True)
    print("wrote", os.path.join(folder, shot["out"]))


def main():
    copy = load_copy()
    parser = argparse.ArgumentParser(description="Compose the App Store screenshots.")
    parser.add_argument("device", nargs="?", choices=sorted(SHOTS), help="only this device")
    parser.add_argument("shot", nargs="?", help="only the image whose file name starts with this, e.g. 02")
    parser.add_argument("--locale", default=SOURCE_LOCALE, choices=sorted(copy) + ["all"],
                        help="a locale from copy.json, or all (default: %(default)s)")
    args = parser.parse_args()
    for locale in sorted(copy) if args.locale == "all" else [args.locale]:
        for device, shots in SHOTS.items():
            if args.device and device != args.device:
                continue
            for shot in shots:
                if args.shot and not shot["out"].startswith(args.shot):
                    continue
                compose(device, shot, locale, headline_text(copy, locale, device, shot))


if __name__ == "__main__":
    main()
