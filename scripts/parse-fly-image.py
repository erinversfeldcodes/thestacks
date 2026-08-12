#!/usr/bin/env python3

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

    if isinstance(d, list) and d:
        d = d[0]

    if isinstance(d, dict):
        for key in ("Ref", "reference", "Reference", "ref"):
            v = d.get(key)
            if v:
                print(v)
                return 0

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
