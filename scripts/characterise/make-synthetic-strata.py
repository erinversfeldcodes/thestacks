#!/usr/bin/env python3
"""Generate the mirrored/rotated and illegible strata from clean originals.

⛔ These two strata are DERIVED, never shot. The corpus plan's sourcing section
names programmatic transforms as the correct source for them: a mirrored barcode
is exactly what pyzbar cannot decode, and reproducing it by hand adds variance
without adding information.

⚠️ The transform is recorded in the filename so a synthetic failure is never
mistaken for a real-world one. That distinction is load-bearing: "the model fails
on mirrored text" and "the model fails on THIS reader's photograph" lead to
different fixes.

⬛ Derived images inherit their source's identity, so no new labelling is needed
and no identity can be invented.
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    from PIL import Image, ImageEnhance, ImageFilter
except ImportError:
    sys.exit("needs Pillow: pip install Pillow")

# (suffix, how to make it) — the plan's stratum 3 and stratum 9.
MIRRORED = (
    ("mirrored", lambda im: im.transpose(Image.Transpose.FLIP_LEFT_RIGHT)),
    ("rot90", lambda im: im.rotate(90, expand=True)),
    ("rot180", lambda im: im.rotate(180, expand=True)),
)

ILLEGIBLE = (
    ("blur", lambda im: im.filter(ImageFilter.GaussianBlur(radius=12))),
    ("dark", lambda im: ImageEnhance.Brightness(im).enhance(0.12)),
)


def main() -> int:
    root = Path(__file__).resolve().parents[2] / "images"
    if not root.is_dir():
        sys.exit(f"no images directory at {root}")

    # Source only from clean barcodes: a mirrored barcode is the point of
    # stratum 3, and an illegible one still has a knowable right answer.
    sources = sorted(root.glob("clean-*.jpg"))
    if not sources:
        sys.exit("no clean-*.jpg originals to derive from")

    made = 0
    for group, transforms, limit in (
        ("mirrored", MIRRORED, 10),
        ("illegible", ILLEGIBLE, 10),
    ):
        count = 0
        for src in sources:
            for suffix, fn in transforms:
                if count >= limit:
                    break
                # The source's identity rides along in its name.
                ident = src.stem.split("-", 1)[1]
                out = root / f"{group}-{ident}-{suffix}.jpg"
                if out.exists():
                    continue
                with Image.open(src) as im:
                    fn(im.convert("RGB")).save(out, quality=88)
                count += 1
                made += 1
            if count >= limit:
                break
        print(f"{group:<10} {count} generated")

    print(f"\n{made} file(s) written to {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
