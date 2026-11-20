#!/usr/bin/env python3
"""Drive the packed + spaced GPU bursts the cost solve needs, directly at Modal.

⛔ THE MISSING HALF OF THE COST LOOP'S TOOLING. The loop's docs say "drive a
controlled burst (slo-load.sh / direct Modal client)" — the former never made
it to disk, so the burst was hand-driven and unrepeatable. This is the direct
Modal client, as a tool:

    PACKED — N serial `VisionModel.analyze` calls through one warm container
             (one cold load, N actives, one trailing window).
    gap    — > the scaledown window, so the packed container dies.
    SPACED — N calls each separated by > the window, forcing N cold containers.

It prints the two UTC windows for `billing-decompose.py --start/--end`, and the
`preview-cost-harness.py --analyze` invocation that solves the constants.

⚠️ It spends real GPU money by design (that is the measurement). N=6 at T4
rates is cents. ⚠️ Billing availability lags: if the decompose shows zeros for
a just-driven window, the bill has not landed yet — retry later rather than
reading absence as free.

Run (repo root, Modal tokens in env):
    python3 scripts/characterise/drive-cost-burst.py \\
        --app thestacks-vision-refactor-vision-redesign-and-w \\
        --image images/clear_cover_01.jpg --n 6 --window-s 60
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import sys
import time
from pathlib import Path


def utc() -> str:
    return dt.datetime.now(dt.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--app", required=True)
    ap.add_argument("--image", required=True, help="a real cover photo, so extract runs")
    ap.add_argument("--n", type=int, default=6)
    ap.add_argument("--window-s", type=int, default=60)
    ap.add_argument(
        "--mode",
        choices=["both", "packed", "spaced"],
        default="both",
        help=(
            "Modal bills by DAY per app, so an intra-day window cannot split "
            "the two patterns on a shared app (measured: sub-day --start/--end "
            "returns zero against day-bucketed rows). One pattern per "
            "DEDICATED app + that app's day total is the clean solve."
        ),
    )
    args = ap.parse_args()

    import modal

    img_b64 = base64.b64encode(Path(args.image).read_bytes()).decode()
    model = modal.Cls.from_name(args.app, "VisionModel")()
    gap = args.window_s + 30

    print(
        f"burst driver: app={args.app} mode={args.mode} n={args.n} "
        f"window={args.window_s}s gap={gap}s"
    )

    if args.mode in ("both", "packed"):
        packed_start = utc()
        for i in range(args.n):
            t0 = time.monotonic()
            model.analyze.remote(img_b64)
            print(f"  packed {i + 1}/{args.n}: {time.monotonic() - t0:.1f}s wall")
        packed_end = utc()
        print(f"packed window: {packed_start} .. {packed_end}")

    if args.mode == "both":
        print(f"waiting {gap}s for the packed container's tail to close…")
        time.sleep(gap)

    if args.mode in ("both", "spaced"):
        spaced_start = utc()
        for i in range(args.n):
            t0 = time.monotonic()
            model.analyze.remote(img_b64)
            print(f"  spaced {i + 1}/{args.n}: {time.monotonic() - t0:.1f}s wall")
            if i < args.n - 1:
                time.sleep(gap)
        # the last container's idle tail belongs to the spaced bill: include it
        time.sleep(gap)
        spaced_end = utc()
        print(f"spaced window: {spaced_start} .. {spaced_end}")
    print("\nnext:")
    print(
        f"  just run python3 scripts/characterise/billing-decompose.py --app {args.app} "
        f"--gpu T4 --identifications {args.n} --start {packed_start} --end {packed_end}"
    )
    print(
        f"  just run python3 scripts/characterise/billing-decompose.py --app {args.app} "
        f"--gpu T4 --identifications {args.n} --start {spaced_start} --end {spaced_end}"
    )
    print(
        f"  just run python3 scripts/characterise/preview-cost-harness.py "
        f"--analyze <gpu_s_packed> <gpu_s_spaced> {args.n} {args.window_s} --gpu T4"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
