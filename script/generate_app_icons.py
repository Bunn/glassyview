#!/usr/bin/env python3
"""Build the iOS Icon Composer documents from the flat 3.0 masters.

The masters in docs/assets/app-icon-masters are opaque 1024 px renders of two
glass panes. iOS can only produce a good clear or tinted icon from separate
foreground layers, so this cuts each pane out along its measured outline and
writes one .icon document per color into dejaview/AppIcons, plus the previews
the in-app picker shows.

Requires Pillow and Xcode 26 or later (for ictool):

    python3 script/generate_app_icons.py
"""
import colorsys
import json
import math
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageOps

ROOT = Path(__file__).resolve().parent.parent
MASTERS = ROOT / "docs/assets/app-icon-masters"
ICONS = ROOT / "dejaview/AppIcons"
PREVIEWS = ROOT / "dejaview/Assets.xcassets/AppIconPreviews"

SIZE = 1024
SUPERSAMPLE = 4
PREVIEW_PIXELS = 192  # 64 pt at 3x

# Sharp-corner outlines (top-left, top-right, bottom-right, bottom-left) and
# corner radii of each pane, measured from the masters.
FRONT = [(124.5, 364.3), (786.0, 291.5), (783.0, 938.6), (125.0, 886.0)]
FRONT_RADII = [72, 60, 78, 62]
BACK = [(312.5, 217.6), (907.5, 115.0), (908.0, 691.5), (312.5, 709.3)]
BACK_RADII = [52, 76, 70, 60]

# Hue is a 0-1 turn added to the masters' blue; saturation is a multiplier.
# `masters` picks which artwork fills the light and dark appearances.
VARIANTS = [
    {"name": "AppIcon", "hue": 0.0, "saturation": 1.0, "masters": ("Light", "Dark")},
    {"name": "AppIconMidnight", "hue": 0.0, "saturation": 1.0, "masters": ("Dark", "Dark")},
    {"name": "AppIconGraphite", "hue": 0.0, "saturation": 0.1, "masters": ("Dark", "Dark")},
    {"name": "AppIconViolet", "hue": 0.155, "saturation": 0.9, "masters": ("Light", "Dark")},
    {"name": "AppIconMint", "hue": -0.12, "saturation": 1.0, "masters": ("Light", "Dark")},
    {"name": "AppIconSunset", "hue": 0.465, "saturation": 0.95, "masters": ("Light", "Dark")},
]

FILLS = {
    "Light": ((0.965, 0.976, 0.984), (0.835, 0.898, 0.984)),
    "Dark": ((0.004, 0.012, 0.090), (0.004, 0.047, 0.190)),
}


def rounded_polygon(points, radii, steps=24):
    path = []
    for index, corner in enumerate(points):
        before, after = points[index - 1], points[(index + 1) % len(points)]
        radius = radii[index]
        to_before = (before[0] - corner[0], before[1] - corner[1])
        to_after = (after[0] - corner[0], after[1] - corner[1])
        before_length, after_length = math.hypot(*to_before), math.hypot(*to_after)
        unit_before = (to_before[0] / before_length, to_before[1] / before_length)
        unit_after = (to_after[0] / after_length, to_after[1] / after_length)
        dot = unit_before[0] * unit_after[0] + unit_before[1] * unit_after[1]
        angle = math.acos(max(-1, min(1, dot)))
        tangent = radius / math.tan(angle / 2)
        start = (corner[0] + unit_before[0] * tangent, corner[1] + unit_before[1] * tangent)
        end = (corner[0] + unit_after[0] * tangent, corner[1] + unit_after[1] * tangent)
        bisector = (unit_before[0] + unit_after[0], unit_before[1] + unit_after[1])
        bisector_length = math.hypot(*bisector)
        reach = radius / math.sin(angle / 2)
        center = (corner[0] + bisector[0] / bisector_length * reach,
                  corner[1] + bisector[1] / bisector_length * reach)
        start_angle = math.atan2(start[1] - center[1], start[0] - center[0])
        sweep = math.atan2(end[1] - center[1], end[0] - center[0]) - start_angle
        sweep = (sweep + math.pi) % (2 * math.pi) - math.pi
        for step in range(steps + 1):
            theta = start_angle + sweep * step / steps
            path.append((center[0] + radius * math.cos(theta), center[1] + radius * math.sin(theta)))
    return path


def inset(points, amount):
    count = len(points)
    center_x = sum(point[0] for point in points) / count
    center_y = sum(point[1] for point in points) / count
    edges = []
    for index, start in enumerate(points):
        end = points[(index + 1) % count]
        dx, dy = end[0] - start[0], end[1] - start[1]
        length = math.hypot(dx, dy)
        normal_x, normal_y = -dy / length, dx / length
        if (center_x - start[0]) * normal_x + (center_y - start[1]) * normal_y < 0:
            normal_x, normal_y = -normal_x, -normal_y
        edges.append(((start[0] + normal_x * amount, start[1] + normal_y * amount), (dx, dy)))
    corners = []
    for index in range(count):
        (point, direction), (other, other_direction) = edges[index - 1], edges[index]
        determinant = direction[0] * other_direction[1] - direction[1] * other_direction[0]
        t = ((other[0] - point[0]) * other_direction[1] - (other[1] - point[1]) * other_direction[0]) / determinant
        corners.append((point[0] + direction[0] * t, point[1] + direction[1] * t))
    return corners


def pane_mask(points, radii, shrink):
    path = rounded_polygon(inset(points, shrink), [radius - shrink for radius in radii])
    canvas = Image.new("L", (SIZE * SUPERSAMPLE, SIZE * SUPERSAMPLE), 0)
    ImageDraw.Draw(canvas).polygon([(x * SUPERSAMPLE, y * SUPERSAMPLE) for x, y in path], fill=255)
    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def recolor(image, hue, saturation):
    if hue == 0 and saturation == 1:
        return image
    h, s, v = image.convert("HSV").split()
    shift = round(hue * 256)
    h = h.point(lambda value: (value + shift) % 256)
    s = s.point(lambda value: min(255, round(value * saturation)))
    return Image.merge("HSV", (h, s, v)).convert("RGB")


def recolor_fill(color, hue, saturation):
    h, s, v = colorsys.rgb_to_hsv(*color)
    return colorsys.hsv_to_rgb((h + hue) % 1, min(1, s * saturation), v)


def cutout(image, mask):
    # The masters carry film grain that is invisible at icon sizes but makes
    # every compiled rendition about twice as large, so smooth it away and
    # drop the color hidden under fully transparent pixels.
    layer = image.filter(ImageFilter.MedianFilter(5)).convert("RGBA")
    layer.putalpha(mask)
    covered = mask.point(lambda value: 255 if value else 0)
    return Image.composite(layer, Image.new("RGBA", layer.size, (0, 0, 0, 0)), covered)


def monochrome(image, mask, low, high):
    gray = ImageOps.grayscale(image).point(lambda value: round(255 * (low + value / 255 * (high - low))))
    return cutout(Image.merge("RGB", (gray, gray, gray)), mask)


def gradient(colors):
    return {
        "linear-gradient": ["srgb:%.5f,%.5f,%.5f,1.00000" % color for color in colors],
        "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}},
    }


def group(layer, title, has_dark_artwork):
    images = [{"value": f"{layer}.png"}]
    if has_dark_artwork:
        images.append({"appearance": "dark", "value": f"{layer}-dark.png"})
    images.append({"appearance": "tinted", "value": f"{layer}-mono.png"})
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
    masters = {name: Image.open(MASTERS / f"Icon-{name}.png").convert("RGB") for name in ("Light", "Dark")}
    front = pane_mask(FRONT, FRONT_RADII, 1)
    back = pane_mask(BACK, BACK_RADII, 1)
    # The colored back cutout stops just inside the front pane so no seam shows.
    visible_back = ImageChops.subtract(back, pane_mask(FRONT, FRONT_RADII, 6))

    for folder in (ICONS, PREVIEWS):
        shutil.rmtree(folder, ignore_errors=True)
        folder.mkdir(parents=True)
    (PREVIEWS / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")

    for variant in VARIANTS:
        hue, saturation = variant["hue"], variant["saturation"]
        light_name, dark_name = variant["masters"]
        light = recolor(masters[light_name], hue, saturation)
        dark = recolor(masters[dark_name], hue, saturation)
        has_dark_artwork = light_name != dark_name
        layers = {
            "front.png": cutout(light, front),
            "front-mono.png": monochrome(masters["Light"], front, 0.45, 1.0),
            "back.png": cutout(light, visible_back),
            "back-mono.png": monochrome(masters["Light"], back, 0.2, 0.8),
        }
        if has_dark_artwork:
            layers["front-dark.png"] = cutout(dark, front)
            layers["back-dark.png"] = cutout(dark, visible_back)
        document = ICONS / f"{variant['name']}.icon"
        (document / "Assets").mkdir(parents=True)
        for filename, layer in layers.items():
            layer.save(document / "Assets" / filename, optimize=True)
        fills = [[recolor_fill(color, hue, saturation) for color in FILLS[name]] for name in (light_name, dark_name)]
        icon = {
            "fill-specializations": [
                {"value": gradient(fills[0])},
                {"appearance": "dark", "value": gradient(fills[1])},
            ],
            "groups": [group("front", "Front Pane", has_dark_artwork), group("back", "Back Pane", has_dark_artwork)],
            "supported-platforms": {"squares": "shared"},
        }
        (document / "icon.json").write_text(json.dumps(icon, indent=2) + "\n")
        write_preview(document, variant["name"])
        print(f"Wrote {document.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
