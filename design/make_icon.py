#!/usr/bin/env python3
"""Optional fallback icon generator - NOT used for the shipped build.

The shipped launcher icon is the upstream one, byte for byte
(design/upstream-icon-192.png). The upstream icon is GPLv3-covered artwork, so
reusing it is compliant; the trademark / likelihood-of-confusion question is
handled separately, in NOTICE and docs/.

This script exists only for the fallback path described in README.md section 8
and docs/upstream-permission-request*.md: if the upstream maintainers decline the
use of the "EtchDroid" name, the port can be re-published under its own name with
a badged, visually distinct icon generated here. Running it rewrites the two
shipped copies, so re-run the build and update NOTICE afterwards.

Run from the project root:
    python3 design/make_icon.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / "design" / "upstream-icon-192.png"
FONT = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"
TARGETS = [
    ROOT / "AppScope" / "resources" / "base" / "media" / "app_icon.png",
    ROOT / "entry" / "src" / "main" / "resources" / "base" / "media" / "startIcon.png",
]

BADGE_TEXT = "鸿蒙"
BADGE_FILL = (10, 89, 247, 255)      # HarmonyOS blue
BADGE_RING = (255, 255, 255, 255)
TEXT_FILL = (255, 255, 255, 255)

SIZE = 192
CENTER = (152, 152)
RADIUS = 36
RING = 5


def build() -> Image.Image:
    icon = Image.open(BASE).convert("RGBA")
    if icon.size != (SIZE, SIZE):
        icon = icon.resize((SIZE, SIZE), Image.LANCZOS)

    draw = ImageDraw.Draw(icon)
    cx, cy = CENTER
    draw.ellipse(
        [cx - RADIUS - RING, cy - RADIUS - RING, cx + RADIUS + RING, cy + RADIUS + RING],
        fill=BADGE_RING,
    )
    draw.ellipse([cx - RADIUS, cy - RADIUS, cx + RADIUS, cy + RADIUS], fill=BADGE_FILL)

    font = ImageFont.truetype(FONT, 30)
    left, top, right, bottom = draw.textbbox((0, 0), BADGE_TEXT, font=font)
    draw.text(
        (cx - (right - left) / 2 - left, cy - (bottom - top) / 2 - top),
        BADGE_TEXT,
        font=font,
        fill=TEXT_FILL,
    )
    return icon


def main() -> None:
    icon = build()
    preview = ROOT / "design" / "app_icon_preview.png"
    icon.save(preview)
    for target in TARGETS:
        icon.save(target)
        print(f"wrote {target.relative_to(ROOT)}")
    print(f"wrote {preview.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
