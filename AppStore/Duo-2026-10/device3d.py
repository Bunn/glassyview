"""Render an iPhone Duo inner display capture as a 3D device for marketing art.

The screen shape comes from the simulator's own inner-display framebuffer mask
(chrome/inner-screen-mask.png, rasterized from the iPhone Duo device type).
The frame copies Device Hub's rendering: a graphite titanium rim, a black
bezel, and hinge notches where the fold meets the side rails.

Each half of the device is a planar slab, so its face maps exactly onto the
canvas with a perspective (homography) transform; slab thickness is drawn by
stacking the face silhouette along its normal.
"""
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
MASK = os.path.join(HERE, "chrome", "inner-screen-mask.png")

BEZEL = 44          # black glass border around the active area, px at 3x
RIM = 26            # titanium band visible from the front
THICKNESS = 40      # half-device thickness, same units
RIM_DARK, RIM_LIGHT = (38, 40, 45), (122, 127, 136)


# Face texture ---------------------------------------------------------------

def _squircle_mask(size, inset, screen_mask):
    """Outer silhouette concentric with the simulator's screen corner shape."""
    grown = Image.new("L", size, 0)
    grown.paste(screen_mask, (inset, inset))
    # Blur-and-threshold dilates the real screen mask by about the inset,
    # keeping its continuous-curvature corners.
    return grown.filter(ImageFilter.GaussianBlur(inset * 0.5)) \
        .point(lambda v: 255 if v > 8 else 0).filter(ImageFilter.GaussianBlur(1.2))


def face_texture(capture):
    """Front of the open device: rim, bezel, and the capture inside the screen mask."""
    screen_mask = Image.open(MASK).getchannel("A")
    if screen_mask.size != capture.size:
        screen_mask = screen_mask.resize(capture.size, Image.LANCZOS)
    inset = BEZEL + RIM
    size = (capture.width + 2 * inset, capture.height + 2 * inset)

    outer = _squircle_mask(size, inset, screen_mask)
    inner_rim = Image.new("L", size, 0)
    inner_rim.paste(screen_mask, (inset, inset))
    inner_rim = inner_rim.filter(ImageFilter.GaussianBlur(BEZEL * 0.5)).point(lambda v: 255 if v > 8 else 0)

    # Brushed graphite rim: vertical light falloff plus a bright outer edge.
    rim = Image.new("RGB", size)
    d = ImageDraw.Draw(rim)
    for y in range(size[1]):
        t = abs(y / size[1] - 0.35)
        c = tuple(round(RIM_LIGHT[i] * (1 - t) * 0.55 + RIM_DARK[i] * (0.45 + t)) for i in range(3))
        d.line([(0, y), (size[0], y)], fill=c)
    face = Image.new("RGBA", size, (0, 0, 0, 0))
    face.paste(rim, (0, 0), outer)
    edge = ImageChops.subtract(outer, outer.filter(ImageFilter.MinFilter(5)))
    face.paste(RIM_LIGHT, (0, 0), edge)
    face.paste((4, 4, 6), (0, 0), inner_rim)

    screen = Image.new("RGBA", size, (0, 0, 0, 0))
    screen.paste(capture.convert("RGB"), (inset, inset), screen_mask)
    face.alpha_composite(screen)

    # Hinge notches: the rails break where the halves meet, as in Device Hub.
    fy = size[1] // 2
    nd = ImageDraw.Draw(face)
    for x0, x1 in ((0, inset - BEZEL + 2), (size[0] - inset + BEZEL - 2, size[0])):
        nd.rectangle([x0, fy - 3, x1, fy + 3], fill=(10, 10, 12, 255))
    return face


# 3D projection --------------------------------------------------------------

def _sub(a, b): return tuple(x - y for x, y in zip(a, b))
def _add(a, b): return tuple(x + y for x, y in zip(a, b))
def _mul(a, k): return tuple(x * k for x in a)


class Camera:
    def __init__(self, yaw, pitch, distance, target):
        self.cy, self.sy = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
        self.cp, self.sp = math.cos(math.radians(pitch)), math.sin(math.radians(pitch))
        self.distance, self.target = distance, target

    def project(self, p):
        x, y, z = _sub(p, self.target)
        x, z = self.cy * x + self.sy * z, -self.sy * x + self.cy * z
        y, z = self.cp * y - self.sp * z, self.sp * y + self.cp * z
        k = self.distance / (self.distance - z)
        return (x * k, -y * k)


class Slab:
    """One half: a textured face with an origin edge on the hinge."""

    def __init__(self, texture, along, normal, half_width):
        self.texture, self.along, self.normal, self.hw = texture, along, normal, half_width

    def corners(self, offset=0.0):
        """TL, TR, BR, BL of the texture in world space, pushed back by offset."""
        back = _mul(self.normal, -offset)
        h = self.texture.height
        hinge_l, hinge_r = (-self.hw, 0, 0), (self.hw, 0, 0)
        far_l, far_r = _add(hinge_l, _mul(self.along, h)), _add(hinge_r, _mul(self.along, h))
        if self.along[1] > 0:   # upper half: texture top is the far edge
            pts = [far_l, far_r, hinge_r, hinge_l]
        else:                   # lower half: texture top is the hinge
            pts = [hinge_l, hinge_r, far_r, far_l]
        return [_add(p, back) for p in pts]


def _solve(a, b):
    n = len(b)
    m = [row[:] + [b[i]] for i, row in enumerate(a)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(m[r][c]))
        m[c], m[p] = m[p], m[c]
        for r in range(n):
            if r != c:
                f = m[r][c] / m[c][c]
                m[r] = [x - f * y for x, y in zip(m[r], m[c])]
    return [m[i][n] / m[i][i] for i in range(n)]


def warp(img, quad, size):
    w, h = img.size
    src = [(0, 0), (w, 0), (w, h), (0, h)]
    rows, rhs = [], []
    for (x, y), (u, v) in zip(quad, src):
        rows.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); rhs.append(u)
        rows.append([0, 0, 0, x, y, 1, -v * x, -v * y]); rhs.append(v)
    return img.transform(size, Image.PERSPECTIVE, _solve(rows, rhs), Image.BICUBIC)


def render(capture, canvas, box, fold_deg, yaw, pitch, lean=12, distance=9000):
    """Draw the device onto canvas, fitted inside box (x0, y0, x1, y1).

    fold_deg 90 lays the lower half on the floor (notebook pose); 0 keeps the
    device flat and upright. lean tilts the upper half back from vertical.
    """
    face = face_texture(capture)
    fy = face.height // 2
    upper, lower = face.crop((0, 0, face.width, fy)), face.crop((0, fy, face.width, face.height))
    hw = face.width / 2

    b = math.radians(fold_deg)
    t = math.radians(lean if fold_deg else 0)
    top = Slab(upper, (0, math.cos(t), -math.sin(t)), (0, math.sin(t), math.cos(t)), hw)
    bottom = Slab(lower, (0, -math.cos(b), math.sin(b)), (0, math.sin(b), math.cos(b)), hw)

    target = (0, upper.height * 0.42, lower.height * 0.35 * math.sin(b))
    cam = Camera(yaw, pitch, distance, target)

    # Fit every projected corner, including the thickness, inside the box.
    pts = [cam.project(p) for s in (top, bottom) for o in (0, THICKNESS) for p in s.corners(o)]
    minx, maxx = min(p[0] for p in pts), max(p[0] for p in pts)
    miny, maxy = min(p[1] for p in pts), max(p[1] for p in pts)
    scale = min((box[2] - box[0]) / (maxx - minx), (box[3] - box[1]) / (maxy - miny))
    ox = (box[0] + box[2]) / 2 - (minx + maxx) / 2 * scale
    oy = (box[1] + box[3]) / 2 - (miny + maxy) / 2 * scale

    def to_canvas(p3):
        x, y = cam.project(p3)
        return (ox + x * scale, oy + y * scale)

    size = canvas.size
    _floor_shadow(canvas, [to_canvas(p) for p in bottom.corners(THICKNESS)] if fold_deg else
                  [to_canvas(p) for p in (top.corners()[0], top.corners()[1],
                                          bottom.corners()[2], bottom.corners()[3])], fold_deg)

    # Back to front: the upper half sits behind the lower half in notebook pose.
    for slab in (top, bottom):
        alpha = slab.texture.getchannel("A")
        steps = 14
        for i in range(steps, 0, -1):
            off = THICKNESS * i / steps
            quad = [to_canvas(p) for p in slab.corners(off)]
            sil = warp(alpha, quad, size)
            shade = 0.55 + 0.45 * (1 - i / steps)
            color = tuple(round(c * shade) for c in (96, 100, 108))
            canvas.paste(color + (255,), (0, 0), sil)
        quad = [to_canvas(p) for p in slab.corners()]
        canvas.alpha_composite(warp(slab.texture, quad, size))
        _glass_sheen(canvas, slab.texture.getchannel("A"), quad, size, slab is top)
    if fold_deg:
        _hinge(canvas, to_canvas((-hw + 30, 0, 0)), to_canvas((hw - 30, 0, 0)), scale)
    return canvas


def _floor_shadow(canvas, quad, fold_deg):
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shift = 40 if fold_deg else 90
    ImageDraw.Draw(layer).polygon([(x, y + shift) for x, y in quad], fill=(0, 0, 0, 170))
    canvas.alpha_composite(layer.filter(ImageFilter.GaussianBlur(60)))
    glow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).polygon(quad, fill=(30, 130, 255, 110))
    canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(120)))


def _glass_sheen(canvas, alpha, quad, size, upper):
    """A soft diagonal reflection across the cover glass."""
    w, h = alpha.size
    sheen = Image.new("L", (w, h), 0)
    sd = ImageDraw.Draw(sheen)
    sd.polygon([(w * 0.05, 0), (w * 0.42, 0), (w * 0.12, h), (-w * 0.25, h)],
               fill=34 if upper else 20)
    sheen = ImageChops.multiply(sheen.filter(ImageFilter.GaussianBlur(w * 0.05)), alpha)
    layer = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    layer.putalpha(sheen)
    canvas.alpha_composite(warp(layer, quad, size))


def _hinge(canvas, left, right, scale):
    r = max(3, THICKNESS * scale * 0.55)
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for i in range(int(r), 0, -1):
        c = round(40 + 70 * (i / r))
        d.line([left, right], fill=(c, c + 3, c + 9, 255), width=i * 2)
    canvas.alpha_composite(layer)
