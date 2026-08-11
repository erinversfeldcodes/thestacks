#!/usr/bin/env python3
"""Generate cinematic textures and assets for The Stacks WebGL bookshelf.

Uses Replicate Flux Dev for high-quality generation.
Idempotent: skips files that already exist unless --force is passed.

Usage:
    source .env
    python3 scripts/generate-textures.py [--force] [--filter CATEGORY]
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
TEXTURE_DIR = REPO_ROOT / "frontend" / "public" / "textures"
MANIFEST_PATH = REPO_ROOT / "frontend" / "public" / "textures" / "manifest.json"


def _asset(category, filename, prompt, width, height):
    return {
        "category": category,
        "filename": filename,
        "prompt": prompt,
        "width": width,
        "height": height,
    }


ASSETS = [
    _asset(
        "normal-maps",
        "normal-leather-burgundy.png",
        "seamless tileable normal map texture of fine-grain "
        "burgundy leather, purple and blue tones representing "
        "surface normals, subtle creases and wrinkles, "
        "uniform lighting, technical texture map",
        512,
        512,
    ),
    _asset(
        "normal-maps",
        "normal-leather-green.png",
        "seamless tileable normal map texture of aged green "
        "leather, purple and blue tones representing surface "
        "normals, fine grain pattern with subtle wear marks, "
        "uniform lighting, technical texture map",
        512,
        512,
    ),
    _asset(
        "normal-maps",
        "normal-leather-navy.png",
        "seamless tileable normal map texture of navy leather "
        "bookbinding, purple and blue tones representing "
        "surface normals, tight grain with embossed borders, "
        "uniform lighting, technical texture map",
        512,
        512,
    ),
    _asset(
        "normal-maps",
        "normal-cloth-weave.png",
        "seamless tileable normal map texture of book cloth "
        "weave, purple and blue tones representing surface "
        "normals, visible cross-hatch thread pattern, "
        "uniform lighting, technical texture map",
        512,
        512,
    ),
    _asset(
        "normal-maps",
        "normal-wood-walnut.png",
        "seamless tileable normal map texture of walnut wood "
        "grain, purple and blue tones representing surface "
        "normals, pronounced grain lines and knots, "
        "uniform lighting, technical texture map",
        512,
        512,
    ),
    _asset(
        "normal-maps",
        "normal-damask.png",
        "seamless tileable normal map texture of damask fabric "
        "pattern, purple and blue tones representing surface "
        "normals, raised floral motif on flat background, "
        "uniform lighting, technical texture map",
        512,
        512,
    ),
    _asset(
        "book-covers",
        "cover-fallback-01.png",
        "vintage hardcover book front cover, dark burgundy "
        "leather with gold embossed ornamental border, "
        "central gold crest, aged patina, no text, "
        "dark academia aesthetic, photorealistic, "
        "dramatic lighting",
        256,
        512,
    ),
    _asset(
        "book-covers",
        "cover-fallback-02.png",
        "vintage hardcover book front cover, forest green "
        "cloth binding with silver art nouveau botanical "
        "frame, central floral medallion, no text, "
        "cottage-core meets dark academia, photorealistic",
        256,
        512,
    ),
    _asset(
        "book-covers",
        "cover-fallback-03.png",
        "vintage hardcover book front cover, midnight navy "
        "leather with copper geometric inlay pattern, "
        "central compass rose, aged edges, no text, "
        "dark academia aesthetic, photorealistic, "
        "moody lighting",
        256,
        512,
    ),
    _asset(
        "book-covers",
        "cover-fallback-04.png",
        "vintage hardcover book front cover, rich brown "
        "tooled leather with blind-stamped celtic knotwork "
        "border, central tree of life motif, worn corners, "
        "no text, photorealistic, warm lighting",
        256,
        512,
    ),
    _asset(
        "book-covers",
        "cover-fallback-05.png",
        "vintage hardcover book front cover, deep plum "
        "velvet with tarnished silver corner pieces and "
        "central lock plate, gothic revival style, no text, "
        "dark academia, photorealistic, dramatic shadows",
        256,
        512,
    ),
    _asset(
        "book-covers",
        "cover-fallback-06.png",
        "vintage hardcover book front cover, olive green "
        "buckram cloth with gilt art deco sunburst pattern, "
        "central eye motif, 1920s aesthetic, no text, "
        "photorealistic, warm golden lighting",
        256,
        512,
    ),
    _asset(
        "book-covers",
        "cover-fallback-07.png",
        "vintage hardcover book front cover, oxblood red "
        "morocco leather with dense gold filigree tooling, "
        "Baroque style, central coat of arms, no text, "
        "museum quality, photorealistic, even lighting",
        256,
        512,
    ),
    _asset(
        "book-covers",
        "cover-fallback-08.png",
        "vintage hardcover book front cover, cream linen "
        "cloth with pressed wildflower botanical illustrations "
        "in muted watercolour, cottage-core aesthetic, "
        "delicate, no text, photorealistic, soft natural light",
        256,
        512,
    ),
    _asset(
        "atmosphere",
        "overlay-light-leak.png",
        "warm golden light leak overlay on pure black "
        "background, soft radial gradient from upper right, "
        "lens flare, cinematic film grain, anamorphic bokeh, "
        "transparent edges fading to black, no objects",
        1024,
        768,
    ),
    _asset(
        "atmosphere",
        "overlay-dust-motes.png",
        "floating dust particles in a beam of warm light on "
        "pure black background, tiny bright specks scattered "
        "across frame, depth of field blur on distant "
        "particles, cinematic, volumetric light, no objects",
        1024,
        768,
    ),
    _asset(
        "atmosphere",
        "overlay-vignette.png",
        "smooth dark vignette overlay on pure black "
        "background, heavy darkening at all edges and corners "
        "fading to transparency in center, oval shape, "
        "cinematic color grade, film grain, no objects",
        1024,
        768,
    ),
    _asset(
        "environment",
        "ceiling-library.png",
        "looking straight up at an ornate dark wood library "
        "ceiling, warm pendant lamps with amber glass shades "
        "casting pools of light, coffered ceiling panels with "
        "carved rosettes, dark walnut beams, rich shadows, "
        "photorealistic, architectural photography",
        1024,
        1024,
    ),
    _asset(
        "environment",
        "floor-hardwood.png",
        "seamless tileable dark walnut hardwood floor texture "
        "seen from above, herringbone parquet pattern, rich "
        "warm brown tones, aged patina, subtle reflections, "
        "photorealistic, interior photography, even lighting",
        512,
        512,
    ),
    _asset(
        "environment",
        "floor-persian-rug.png",
        "seamless tileable persian rug texture from above, "
        "deep crimson and navy with gold and cream accents, "
        "intricate traditional medallion pattern, worn vintage "
        "patina, dark academia interior, photorealistic, "
        "even overhead lighting",
        512,
        512,
    ),
    _asset(
        "wood",
        "wood-walnut-shelf-hq.png",
        "seamless tileable dark walnut wood plank texture, "
        "close-up of polished bookshelf surface, visible "
        "grain lines and subtle figure, warm brown tones "
        "with honey highlights, photorealistic, "
        "studio macro photography, even lighting",
        1024,
        256,
    ),
    _asset(
        "wood",
        "wood-side-panel.png",
        "seamless tileable dark walnut wood vertical grain "
        "texture, bookcase side panel, rich brown with subtle "
        "cathedral grain pattern, slightly worn edges, "
        "photorealistic, architectural detail, even lighting",
        256,
        1024,
    ),
]

MAX_RETRIES = 5
BASE_DELAY = 12  # rate limit is 6/min so ~10s between requests


def generate_asset(asset: dict, client, force: bool = False) -> dict:
    """Generate a single asset with retry-on-429."""
    import requests as http_requests

    out_path = TEXTURE_DIR / asset["filename"]

    if out_path.exists() and not force:
        return {
            "filename": asset["filename"],
            "status": "skipped",
            "path": str(out_path),
        }

    print(
        f"  Generating {asset['filename']}...",
        end=" ",
        flush=True,
    )
    start = time.time()
    last_error = None

    for attempt in range(MAX_RETRIES):
        try:
            output = client.run(
                "black-forest-labs/flux-dev",
                input={
                    "prompt": asset["prompt"],
                    "width": asset["width"],
                    "height": asset["height"],
                    "num_outputs": 1,
                    "output_format": "png",
                    "guidance": 3.5,
                    "num_inference_steps": 28,
                },
            )

            item = output[0] if isinstance(output, list) and output else output
            url = item.url if hasattr(item, "url") else str(item)

            resp = http_requests.get(url, timeout=120)
            resp.raise_for_status()
            out_path.write_bytes(resp.content)

            elapsed = time.time() - start
            size_kb = len(resp.content) / 1024
            print(f"OK ({elapsed:.1f}s, {size_kb:.0f}KB)")

            return {
                "filename": asset["filename"],
                "status": "generated",
                "path": str(out_path),
                "prompt": asset["prompt"],
                "dimensions": (f"{asset['width']}x{asset['height']}"),
                "size_kb": round(size_kb),
                "elapsed_s": round(elapsed, 1),
            }

        except Exception as e:
            last_error = e
            if "429" in str(e) and attempt < MAX_RETRIES - 1:
                delay = BASE_DELAY * (attempt + 1)
                print(
                    f"rate-limited, waiting {delay}s...",
                    end=" ",
                    flush=True,
                )
                time.sleep(delay)
            else:
                break

    elapsed = time.time() - start
    print(f"FAILED ({elapsed:.1f}s): {last_error}")
    return {
        "filename": asset["filename"],
        "status": "failed",
        "error": str(last_error),
    }


def main():
    parser = argparse.ArgumentParser(description="Generate cinematic textures")
    parser.add_argument(
        "--force",
        action="store_true",
        help="Regenerate existing files",
    )
    parser.add_argument(
        "--filter",
        type=str,
        help="Only generate assets in this category",
    )
    args = parser.parse_args()

    token = os.environ.get("REPLICATE_TOKEN") or os.environ.get("REPLICATE_API_TOKEN")
    if not token:
        print("Error: REPLICATE_TOKEN not set. Run: source .env")
        sys.exit(1)

    import replicate

    client = replicate.Client(api_token=token)

    TEXTURE_DIR.mkdir(parents=True, exist_ok=True)

    assets = ASSETS
    if args.filter:
        assets = [a for a in ASSETS if a["category"] == args.filter]
        if not assets:
            cats = sorted(set(a["category"] for a in ASSETS))
            print(f"No assets in category '{args.filter}'. Available: {', '.join(cats)}")
            sys.exit(1)

    total = len(assets)
    print(f"Generating {total} assets (Flux Dev, quality mode)...")
    print(f"Output: {TEXTURE_DIR}/")
    if not args.force:
        print("(Skipping existing files. Use --force to regenerate.)")
    print()

    results = []
    for i, asset in enumerate(assets, 1):
        cat = asset["category"]
        print(f"[{i}/{total}] ({cat}) ", end="")
        result = generate_asset(asset, client, force=args.force)
        results.append(result)

    manifest = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "model": "black-forest-labs/flux-dev",
        "assets": results,
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2))

    generated = sum(1 for r in results if r["status"] == "generated")
    skipped = sum(1 for r in results if r["status"] == "skipped")
    failed = sum(1 for r in results if r["status"] == "failed")
    print(f"\nDone: {generated} generated, {skipped} skipped, {failed} failed")
    print(f"Manifest: {MANIFEST_PATH}")


if __name__ == "__main__":
    main()
