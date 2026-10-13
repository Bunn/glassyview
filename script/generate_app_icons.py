#!/usr/bin/env python3
"""Build the iOS Icon Composer documents for Glassy Desk.

Each icon is two glass panes drawn as vector layers, so iOS can rasterize
them cleanly at every size and render the clear and tinted styles from real
foreground shapes. The pane outlines and sweeps follow the flat 3.0 masters
kept in docs/assets/app-icon-masters. Bitmap layers are not an option here:
iOS shrinks them without filtering, which leaves the slanted edges jagged.

Writes one .icon document per color into dejaview/AppIcons, plus the
previews the in-app picker shows. Requires Xcode 26 or later (for ictool):

    python3 script/generate_app_icons.py
"""
import colorsys
import json
import math
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ICONS = ROOT / "dejaview/AppIcons"
PREVIEWS = ROOT / "dejaview/Assets.xcassets/AppIconPreviews"

SIZE = 1024
PREVIEW_PIXELS = 192  # 64 pt at 3x

# Sharp-corner outlines (top-left, top-right, bottom-right, bottom-left) and
# corner radii of each pane, measured from the masters.
FRONT = [(124.5, 364.3), (786.0, 291.5), (783.0, 938.6), (125.0, 886.0)]
FRONT_RADII = [72, 60, 78, 62]
BACK = [(312.5, 217.6), (907.5, 115.0), (908.0, 691.5), (312.5, 709.3)]
BACK_RADII = [52, 76, 70, 60]

# The two light sweeps across the front pane, as circles (center x, center y, radius).
RISING_SWEEP = (0, 1000, 725)
HORIZON_SWEEP = (420, 1479, 934)
CROSSING = (583, 559)

# Colors of the blue icon. Every other color is a hue and saturation shift of these.
PALETTES = {
    "light": {
        "sky": ("#B9DCFC", "#6FB2FA"),
        "body": ("#2F8BF9", "#0346EC", "#0E6CF6"),
        "back": ("#9CCBFB", "#2F7DF3", "#0432BE"),
        "glow": ("#FFFFFF", 0.8, 0.22),
        "sweep": ("#FFFFFF", 0.85),
        "rim": ("#FFFFFF", 0.92),
        "back_rim": ("#EAF5FF", 0.85),
        "fill": ("#F6F9FB", "#D5E5FB"),
    },
    "dark": {
        "sky": ("#3D74CC", "#0A2A7C"),
        "body": ("#0B3AA8", "#000A48", "#00176A"),
        "back": ("#2456C4", "#06207E", "#000A4A"),
        "glow": ("#63B8FF", 0.45, 0.16),
        "sweep": ("#8FD6FF", 0.9),
        "rim": ("#CFEBFF", 0.92),
        "back_rim": ("#7FB6F5", 0.8),
        "fill": ("#010317", "#010C30"),
    },
    "mono": {
        "sky": ("#F2F2F2", "#D0D0D0"),
        "body": ("#BDBDBD", "#8E8E8E", "#969696"),
        "back": ("#C4C4C4", "#8A8A8A", "#5E5E5E"),
        "glow": ("#FFFFFF", 0.7, 0.15),
        "sweep": ("#FFFFFF", 0.85),
        "rim": ("#FFFFFF", 0.95),
        "back_rim": ("#FFFFFF", 0.7),
    },
}

# Hue is a 0-1 turn added to the blue; saturation is a multiplier. `palettes`
# picks which colors fill the light and dark appearances.
VARIANTS = [
    {"name": "AppIcon", "hue": 0.0, "saturation": 1.0, "palettes": ("light", "dark")},
    {"name": "AppIconMidnight", "hue": 0.0, "saturation": 1.0, "palettes": ("dark", "dark")},
    {"name": "AppIconGraphite", "hue": 0.0, "saturation": 0.08, "palettes": ("dark", "dark")},
    {"name": "AppIconViolet", "hue": 0.155, "saturation": 0.9, "palettes": ("light", "dark")},
    {"name": "AppIconMint", "hue": -0.12, "saturation": 0.95, "palettes": ("light", "dark")},
    {"name": "AppIconSunset", "hue": 0.465, "saturation": 0.95, "palettes": ("light", "dark")},
]


def rgb(hex_color):
    return tuple(int(hex_color[index:index + 2], 16) / 255 for index in (1, 3, 5))


def recolor(hex_color, hue, saturation):
    h, s, v = colorsys.rgb_to_hsv(*rgb(hex_color))
    red, green, blue = colorsys.hsv_to_rgb((h + hue) % 1, min(1, s * saturation), v)
    return "#%02X%02X%02X" % (round(red * 255), round(green * 255), round(blue * 255))


def recolor_palette(palette, hue, saturation):
    def shift(value):
        if isinstance(value, str):
            return recolor(value, hue, saturation)
        if isinstance(value, tuple):
            return tuple(shift(item) for item in value)
        return value
    return {key: shift(value) for key, value in palette.items()}


def pane_path(points, radii):
    """A closed path around `points` with each corner rounded to its radius."""
    commands = []
    for index, corner in enumerate(points):
        before, after = points[index - 1], points[(index + 1) % len(points)]
        to_before = (before[0] - corner[0], before[1] - corner[1])
        to_after = (after[0] - corner[0], after[1] - corner[1])
        before_length, after_length = math.hypot(*to_before), math.hypot(*to_after)
        dot = (to_before[0] * to_after[0] + to_before[1] * to_after[1]) / (before_length * after_length)
        tangent = radii[index] / math.tan(math.acos(max(-1, min(1, dot))) / 2)
        start = (corner[0] + to_before[0] / before_length * tangent, corner[1] + to_before[1] / before_length * tangent)
        end = (corner[0] + to_after[0] / after_length * tangent, corner[1] + to_after[1] / after_length * tangent)
        # A cubic with 0.5523 handles is the usual stand-in for a circular arc.
        handle = 1 - 0.5523
        first = (start[0] + (corner[0] - start[0]) * (1 - handle), start[1] + (corner[1] - start[1]) * (1 - handle))
        second = (end[0] + (corner[0] - end[0]) * (1 - handle), end[1] + (corner[1] - end[1]) * (1 - handle))
        commands.append("%s%.2f %.2f" % ("M" if index == 0 else "L", *start))
        commands.append("C%.2f %.2f %.2f %.2f %.2f %.2f" % (*first, *second, *end))
    return " ".join(commands) + " Z"


def vertical_gradient(identifier, top, bottom, stops):
    rows = "".join(
        f'<stop offset="{offset}" stop-color="{color}" stop-opacity="{opacity}"/>'
        for offset, color, opacity in stops
    )
    return (f'<linearGradient id="{identifier}" gradientUnits="userSpaceOnUse" '
            f'x1="0" y1="{top}" x2="0" y2="{bottom}">{rows}</linearGradient>')


def svg(definitions, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">'
            f'<defs>{definitions}</defs>{body}</svg>\n')


def soft_stroke(shape, paint, opacity, widths):
    """Stacked strokes that fade with distance from the line.

    A single hard stroke is about one pixel wide on the Home Screen, where a
    slanted line that thin turns into a staircase; a soft falloff does not.
    """
    layer = 1 - (1 - opacity) ** (1 / len(widths))
    return "".join(
        f'<{shape} fill="none" stroke="{paint}" stroke-opacity="{layer:.3f}" stroke-width="{width}"/>'
        for width in widths
    )


# Stroke widths are centered on the outline, so half of each rim is clipped away.
RIM_WIDTHS = (6, 12, 18, 24, 32)
SWEEP_WIDTHS = (4, 9, 16)


def front_svg(palette):
    outline = pane_path(FRONT, FRONT_RADII)
    glow_color, glow_top, glow_bottom = palette["glow"]
    sweep_color, sweep_opacity = palette["sweep"]
    rim_color, rim_opacity = palette["rim"]
    definitions = (
        f'<clipPath id="pane"><path d="{outline}"/></clipPath>'
        + vertical_gradient("sky", 300, 640, [(0, palette["sky"][0], 1), (1, palette["sky"][1], 1)])
        + vertical_gradient("body", 545, 940, [(0, palette["body"][0], 1), (0.8, palette["body"][1], 1),
                                               (1, palette["body"][2], 1)])
        + vertical_gradient("glow", 300, 640, [(0, glow_color, glow_top), (1, glow_color, glow_top * 0.55)])
        + vertical_gradient("lowglow", 545, 940, [(0, glow_color, glow_bottom), (1, glow_color, 0)])
        # A flare where the two sweeps cross.
        + (f'<radialGradient id="flare" gradientUnits="userSpaceOnUse" cx="{CROSSING[0]}" cy="{CROSSING[1]}" r="170">'
           f'<stop offset="0" stop-color="{sweep_color}" stop-opacity="{sweep_opacity * 0.6}"/>'
           f'<stop offset="1" stop-color="{sweep_color}" stop-opacity="0"/></radialGradient>')
        # Each sweep is brightest where the two cross and fades toward the pane's edges.
        + (f'<linearGradient id="sweep" gradientUnits="userSpaceOnUse" x1="125" y1="0" x2="785" y2="0">'
           f'<stop offset="0" stop-color="{sweep_color}" stop-opacity="{sweep_opacity * 0.25}"/>'
           f'<stop offset="0.68" stop-color="{sweep_color}" stop-opacity="{sweep_opacity}"/>'
           f'<stop offset="1" stop-color="{sweep_color}" stop-opacity="{sweep_opacity * 0.2}"/></linearGradient>')
    )
    rising = 'cx="%d" cy="%d" r="%d"' % RISING_SWEEP
    horizon = 'cx="%d" cy="%d" r="%d"' % HORIZON_SWEEP
    body = (
        '<g clip-path="url(#pane)">'
        f'<path d="{outline}" fill="url(#sky)"/>'
        f'<circle {rising} fill="url(#glow)"/>'
        f'<circle {horizon} fill="url(#body)"/>'
        f'<circle {rising} fill="url(#lowglow)"/>'
        f'<circle cx="{CROSSING[0]}" cy="{CROSSING[1]}" r="170" fill="url(#flare)"/>'
        + soft_stroke(f'circle {horizon}', "url(#sweep)", 0.75, SWEEP_WIDTHS)
        + soft_stroke(f'circle {rising}', "url(#sweep)", 0.75, SWEEP_WIDTHS)
        + soft_stroke(f'path d="{outline}"', rim_color, rim_opacity, RIM_WIDTHS) +
        '</g>'
    )
    return svg(definitions, body)


def back_svg(palette):
    outline = pane_path(BACK, BACK_RADII)
    rim_color, rim_opacity = palette["back_rim"]
    top, middle, bottom = palette["back"]
    definitions = (
        f'<clipPath id="pane"><path d="{outline}"/></clipPath>'
        f'<linearGradient id="body" gradientUnits="userSpaceOnUse" x1="420" y1="140" x2="820" y2="700">'
        f'<stop offset="0" stop-color="{top}"/><stop offset="0.5" stop-color="{middle}"/>'
        f'<stop offset="1" stop-color="{bottom}"/></linearGradient>'
    )
    body = (
        '<g clip-path="url(#pane)">'
        f'<path d="{outline}" fill="url(#body)"/>'
        + soft_stroke(f'path d="{outline}"', rim_color, rim_opacity, RIM_WIDTHS) +
        '</g>'
    )
    return svg(definitions, body)


def background(colors):
    return {
        "linear-gradient": ["srgb:%.5f,%.5f,%.5f,1.00000" % rgb(color) for color in colors],
        "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}},
    }


def group(layer, title, has_dark_artwork):
    images = [{"value": f"{layer}.svg"}]
    if has_dark_artwork:
        images.append({"appearance": "dark", "value": f"{layer}-dark.svg"})
    images.append({"appearance": "tinted", "value": f"{layer}-mono.svg"})
    return {
        "layers": [{"name": title, "glass": True, "image-name-specializations": images}],
        "shadow": {"kind": "neutral", "opacity": 0.35},
        "specular": True,
        # Only the clear and tinted appearances let the back pane show through.
        "translucency-specializations": [
            {"value": {"enabled": False, "value": 0.5}},
            {"appearance": "tinted", "value": {"enabled": True, "value": 0.4}},
        ],
    }


def ictool():
    xcode = subprocess.run(["xcode-select", "-p"], check=True, capture_output=True, text=True).stdout.strip()
    return Path(xcode).parent / "Applications/Icon Composer.app/Contents/Executables/ictool"


def write_preview(document, name):
    imageset = PREVIEWS / f"{name}.imageset"
    imageset.mkdir(parents=True)
    subprocess.run([
        str(ictool()), str(document), "--export-image", "--output-file", str(imageset / f"{name}.png"),
        "--platform", "iOS", "--rendition", "Default",
        "--width", str(PREVIEW_PIXELS), "--height", str(PREVIEW_PIXELS), "--scale", "1",
    ], check=True, capture_output=True)
    contents = {
        "images": [{"filename": f"{name}.png", "idiom": "universal", "scale": "3x"}],
        "info": {"author": "xcode", "version": 1},
    }
    (imageset / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def main():
    for folder in (ICONS, PREVIEWS):
        shutil.rmtree(folder, ignore_errors=True)
        folder.mkdir(parents=True)
    (PREVIEWS / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")

    for variant in VARIANTS:
        light_name, dark_name = variant["palettes"]
        light = recolor_palette(PALETTES[light_name], variant["hue"], variant["saturation"])
        dark = recolor_palette(PALETTES[dark_name], variant["hue"], variant["saturation"])
        has_dark_artwork = light_name != dark_name
        layers = {
            "front.svg": front_svg(light),
            "front-mono.svg": front_svg(PALETTES["mono"]),
            "back.svg": back_svg(light),
            "back-mono.svg": back_svg(PALETTES["mono"]),
        }
        if has_dark_artwork:
            layers["front-dark.svg"] = front_svg(dark)
            layers["back-dark.svg"] = back_svg(dark)

        document = ICONS / f"{variant['name']}.icon"
        (document / "Assets").mkdir(parents=True)
        for filename, contents in layers.items():
            (document / "Assets" / filename).write_text(contents)
        icon = {
            "fill-specializations": [
                {"value": background(light["fill"])},
                {"appearance": "dark", "value": background(dark["fill"])},
            ],
            "groups": [group("front", "Front Pane", has_dark_artwork), group("back", "Back Pane", has_dark_artwork)],
            "supported-platforms": {"squares": "shared"},
        }
        (document / "icon.json").write_text(json.dumps(icon, indent=2) + "\n")
        write_preview(document, variant["name"])
        print(f"Wrote {document.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
