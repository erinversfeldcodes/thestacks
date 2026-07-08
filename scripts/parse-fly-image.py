#!/usr/bin/env python3
# scripts/parse-fly-image.py — parse `fly image show --json` output into a
# usable image reference for `fly deploy --image`.
#
# Field-name casing has drifted across flyctl versions (older builds emitted
# `Ref`; newer ones may emit `reference` or nest the data differently).
# Some versions return a flat object; current versions return a list of
# per-machine objects. This parser tries multiple known shapes and falls
# back to synthesising `registry/repo@digest` (or `:tag`) from the
# components when no top-level ref field is present.
#
# Usage:
#   fly image show --app <app> --json > /tmp/fly-image.json
#   python3 scripts/parse-fly-image.py /tmp/fly-image.json
#
# Exit codes:
#   0  — image ref printed to stdout
#   1  — parse error or no recognisable field; reason printed to stderr
#
# Intended caller: .github/workflows/deploy-production.yml's
# `record-prev-state` step.

import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: parse-fly-image.py <path-to-fly-image-json>", file=sys.stderr)
        return 1
    path = sys.argv[1]
    try:
        with open(path) as f:
            d = json.load(f)
    except Exception as e:
        print(f"JSON parse failed: {e}", file=sys.stderr)
        return 1

    # Some flyctl versions return a list of per-machine objects; pick the
    # first (all machines on a healthy app run the same image).
    if isinstance(d, list) and d:
        d = d[0]

    # Try known top-level ref field names in priority order.
    if isinstance(d, dict):
        for key in ("Ref", "reference", "Reference", "ref"):
            v = d.get(key)
            if v:
                print(v)
                return 0

        # Fallback: synthesise from Registry/Repository/Tag/Digest. Prefer
        # digest over tag because digest pins exactly; tag can drift.
        reg = d.get("Registry") or d.get("registry") or ""
        repo = d.get("Repository") or d.get("repository") or ""
        digest = d.get("Digest") or d.get("digest") or ""
        tag = d.get("Tag") or d.get("tag") or ""
        if reg and repo and (digest or tag):
            if digest:
                print(f"{reg}/{repo}@{digest}")
            else:
                print(f"{reg}/{repo}:{tag}")
            return 0

        print(
            f"no recognised image-ref field. Keys present: {list(d.keys())}",
            file=sys.stderr,
        )
        return 1

    print(f"unexpected JSON shape: {type(d).__name__}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
