#!/usr/bin/env python3
"""Generate the androcall application icon.

The icon is drawn programmatically (no binary assets are checked in) so that it
can be regenerated and reviewed as code. It produces every size the macOS
``iconutil`` tool needs and then packs them into ``AppIcon.icns``.

Usage: python3 scripts/make_icon.py
"""

from __future__ import annotations

import os
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
RESOURCES = os.path.join(REPO, "macos", "Resources")
ICONSET = os.path.join(RESOURCES, "AppIcon.iconset")

# The sizes ``iconutil`` expects in an .iconset directory.
SIZES = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

BACKGROUND_TOP = (48, 104, 214)
BACKGROUND_BOTTOM = (24, 62, 158)
FOREGROUND = (255, 255, 255)


def lerp(a: int, b: int, t: float) -> int:
    return int(round(a + (b - a) * t))


def blend(color_a, color_b, t: float):
    return tuple(lerp(color_a[i], color_b[i], t) for i in range(3))


def draw_icon(size: int):
    """Draw the icon at ``size`` pixels square and return an RGBA image."""
    from PIL import Image, ImageDraw

    supersample = 4
    canvas_size = size * supersample
    image = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    # Rounded-square background with a vertical gradient.
    radius = int(canvas_size * 0.2237)  # the macOS "squircle" approximation
    gradient = Image.new("RGBA", (canvas_size, canvas_size))
    gradient_pixels = gradient.load()
    for y in range(canvas_size):
        t = y / max(1, canvas_size - 1)
        color = blend(BACKGROUND_TOP, BACKGROUND_BOTTOM, t)
        for x in range(canvas_size):
            gradient_pixels[x, y] = color + (255,)
    mask = Image.new("L", (canvas_size, canvas_size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, canvas_size - 1, canvas_size - 1], radius=radius, fill=255
    )
    image.paste(gradient, (0, 0), mask)

    # A phone outline with a sound wave — "a call coming from a phone".
    inset = canvas_size * 0.24
    phone_width = canvas_size * 0.30
    phone_height = canvas_size * 0.46
    phone_left = canvas_size * 0.235
    phone_top = (canvas_size - phone_height) / 2
    phone_right = phone_left + phone_width
    phone_bottom = phone_top + phone_height
    stroke = max(2, int(canvas_size * 0.042))

    draw.rounded_rectangle(
        [phone_left, phone_top, phone_right, phone_bottom],
        radius=canvas_size * 0.055,
        outline=FOREGROUND + (255,),
        width=stroke,
    )
    # The home indicator.
    draw.rounded_rectangle(
        [
            phone_left + phone_width * 0.30,
            phone_bottom - canvas_size * 0.075,
            phone_right - phone_width * 0.30,
            phone_bottom - canvas_size * 0.045,
        ],
        radius=stroke,
        fill=FOREGROUND + (255,),
    )

    # Two sound arcs to the right of the phone.
    arc_box = [
        phone_right - canvas_size * 0.02,
        canvas_size * 0.34,
        phone_right + canvas_size * 0.30,
        canvas_size * 0.66,
    ]
    draw.arc(arc_box, start=-58, end=58, fill=FOREGROUND + (255,), width=stroke)
    arc_box2 = [
        phone_right - canvas_size * 0.06,
        canvas_size * 0.27,
        phone_right + canvas_size * 0.40,
        canvas_size * 0.73,
    ]
    draw.arc(arc_box2, start=-52, end=52, fill=FOREGROUND + (200,), width=stroke)

    return image.resize((size, size), Image.LANCZOS)


def main() -> int:
    try:
        from PIL import Image  # noqa: F401
    except ImportError:
        print("Pillow is required: python3 -m pip install --user Pillow", file=sys.stderr)
        return 1

    os.makedirs(ICONSET, exist_ok=True)
    for base, scale in SIZES:
        size = base * scale
        image = draw_icon(size)
        suffix = "" if scale == 1 else f"@{scale}x"
        name = f"icon_{base}x{base}{suffix}.png"
        image.save(os.path.join(ICONSET, name))

    icns = os.path.join(RESOURCES, "AppIcon.icns")
    if os.path.exists(icns):
        os.remove(icns)
    subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", icns], check=True)
    print(f"wrote {icns}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
