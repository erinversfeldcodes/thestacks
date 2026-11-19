#!/usr/bin/env python3
"""Recall@k of a cover/spine embedding index over the reader's OWN library.

⬛ THE ROLE UNDER MEASUREMENT is the one the accuracy program relocated the
technique to: a CANDIDATE GENERATOR over a small catalogue (the reader's own
books), never a decider over the full catalogue — the regime inversion
(embeddings win small catalogues, lose at 2.3M titles) is the whole reason the
roles were split, and the ISBN gate still verifies whatever lands in the top-k.

Protocol: the "library" is one image per distinct labelled ISBN in the eval
corpus (the cleanest available: clear_cover first). Every OTHER image of the
same ISBN becomes a query — a degraded photo (rotated, glare, barcode side)
matched against a clean index, which is exactly the re-identification shape.
Recall@1/@5 per stratum, with n stated on every line.

⚠️ HONEST-N GUARD: today's corpus has few multi-image books, so the dry-run
number is a smoke-level signal that the harness works end to end — NOT the
experiment. The experiment runs when the owner's spine photographs land (they
add multi-image books by design). The script refuses to print a recall line
for a stratum without stating its n, and refuses to run at all when the
query set is empty — a 0/0 that prints as a percentage is the silent zero
this repo keeps relearning.

Setup (one-time; CPU-only, macOS wheels are small):
    python3 -m venv scripts/characterise/.venv-visual
    scripts/characterise/.venv-visual/bin/pip install torch torchvision open_clip_torch pillow
Run (from the repo root):
    scripts/characterise/.venv-visual/bin/python scripts/characterise/visual-recall.py
"""

from __future__ import annotations

import re
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CORPUS = REPO / "apps/core/priv/eval/vision_corpus.exs"
MODEL = "ViT-B-32"
PRETRAINED = "laion2b_s34b_b79k"

# The cleanest-first preference for which image represents a book in the
# library index. Everything else about that book becomes a query.
INDEX_PREFERENCE = [
    "clear_cover",
    "hostile_typography",
    "clean_barcode",
    "text_clutter",
    "hostile_orientation",
    "hostile_barcode",
    "occlusion",
    "illegible",
    "multiple_books",
    "book_adjacent",
]


def parse_corpus() -> list[dict[str, str]]:
    """Entry-shape-coupled on purpose: the corpus file is the single source of
    truth and its entries are regular; a parse miss shows up as a wrong total
    against the count the eval harness prints (122 today)."""
    src = CORPUS.read_text()
    out = []
    for m in re.finditer(r"%\{(.*?)\n  \}", src, re.S):
        body = m.group(1)
        path = re.search(r'path: "([^"]+)"', body)
        isbn = re.search(r'expect_isbn: "(\d+)"', body)
        stratum = re.search(r"stratum: :(\w+)", body)
        if path and isbn and stratum:
            out.append(
                {
                    "path": path.group(1),
                    "isbn": isbn.group(1),
                    "stratum": stratum.group(1),
                }
            )
    return out


def split_index_queries(
    entries: list[dict[str, str]],
) -> tuple[dict[str, dict[str, str]], list[dict[str, str]]]:
    by_isbn: dict[str, list[dict[str, str]]] = defaultdict(list)
    for e in entries:
        by_isbn[e["isbn"]].append(e)

    rank = {s: i for i, s in enumerate(INDEX_PREFERENCE)}
    index: dict[str, dict[str, str]] = {}
    queries: list[dict[str, str]] = []
    for isbn, group in by_isbn.items():
        group = sorted(group, key=lambda e: rank.get(e["stratum"], len(rank)))
        index[isbn] = group[0]
        queries.extend(group[1:])
    return index, queries


def main() -> int:
    entries = parse_corpus()
    if not entries:
        sys.exit("FAIL: parsed 0 labelled entries from the corpus — the parse is broken")

    index, queries = split_index_queries(entries)
    print(
        f"library index: {len(index)} books (one image each) | "
        f"queries: {len(queries)} degraded photos of indexed books"
    )
    if not queries:
        sys.exit(
            "FAIL: no book has a second image, so recall is unmeasurable — "
            "0/0 printed as a score would be a lie. Add multi-image books "
            "(the spine photographs) and re-run."
        )

    try:
        import open_clip
        import torch
        from PIL import Image
    except ImportError:
        sys.exit(
            "FAIL: encoder deps missing. One-time setup:\n"
            "  python3 -m venv scripts/characterise/.venv-visual\n"
            "  scripts/characterise/.venv-visual/bin/pip install "
            "torch torchvision open_clip_torch pillow"
        )

    model, _, preprocess = open_clip.create_model_and_transforms(MODEL, pretrained=PRETRAINED)
    model.eval()

    def embed(path: Path) -> torch.Tensor:
        with Image.open(path) as im:
            x = preprocess(im.convert("RGB")).unsqueeze(0)
        with torch.no_grad():
            v = model.encode_image(x)
        return (v / v.norm(dim=-1, keepdim=True)).squeeze(0)

    isbns = list(index.keys())
    print(f"encoding {len(isbns)} index images + {len(queries)} queries on CPU ({MODEL})…")
    index_matrix = torch.stack([embed(REPO / index[i]["path"]) for i in isbns])

    per_stratum: dict[str, list[tuple[bool, bool]]] = defaultdict(list)
    for q in queries:
        sims = index_matrix @ embed(REPO / q["path"])
        top = [isbns[i] for i in sims.argsort(descending=True)[:5].tolist()]
        hit1 = top[0] == q["isbn"]
        hit5 = q["isbn"] in top
        per_stratum[q["stratum"]].append((hit1, hit5))

    print(f"\nmodel: {MODEL}/{PRETRAINED} | index n={len(isbns)} | queries n={len(queries)}")
    all_rows = [r for rows in per_stratum.values() for r in rows]
    for stratum in sorted(per_stratum):
        rows = per_stratum[stratum]
        r1 = sum(1 for h1, _ in rows if h1)
        r5 = sum(1 for _, h5 in rows if h5)
        print(f"  {stratum:<22} recall@1 {r1}/{len(rows)}   recall@5 {r5}/{len(rows)}")
    r1 = sum(1 for h1, _ in all_rows if h1)
    r5 = sum(1 for _, h5 in all_rows if h5)
    print(f"  {'TOTAL':<22} recall@1 {r1}/{len(all_rows)}   recall@5 {r5}/{len(all_rows)}")
    print(
        "\n⚠️ interpret with the n above — the experiment proper needs the spine "
        "photographs; this run proves the harness and gives a smoke-level prior."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
