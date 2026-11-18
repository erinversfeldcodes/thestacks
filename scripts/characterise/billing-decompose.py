"""What Modal ACTUALLY billed for a window of vision traffic, per identification.

⛔ THE GROUND-TRUTH SIDE OF THE COST LOOP. `vision-cost-decomposition.py` reads
eval artefacts and estimates cost from the published rate — a prediction.
This reads `modal billing report --json` and reports what was *charged*. Run
both over the same window and the gap between them is the cost model's error,
measured rather than assumed. This is what lets a preview answer "what will
this architecture cost" BEFORE it ships, instead of waiting for a month of
production billing — the capability the cost-characterisation work actually needs.

⚠️ WHAT "PER IDENTIFICATION" MEANS HERE, EXACTLY. Billing gives total
GPU-seconds for a window: active inference + cold loads + idle tails, summed
over every container alive in it. Divided by N identifications it is the
ALL-IN cost per id for THAT window's arrival pattern — which is precisely what
the frontier's per-id OUTPUT predicts, so it validates that output directly.
It is NOT the frontier's ACTIVE_S input; isolating that needs two load
patterns (packed vs spaced), which the harness that calls this does. So the
per-id number is only meaningful if N is the identifications driven in exactly
the --start/--end window, and the script refuses to pretend otherwise.

⚠️ READ-ONLY. It shells `modal billing report` (a read) or reads a saved JSON;
it never deploys, drives traffic, or writes outside its given output path.

Usage:
    # live, against a just-driven preview window:
    python3 -I scripts/characterise/billing-decompose.py \\
        --app thestacks-vision-exp-4 --start 2026-11-17T14:00 --end 2026-11-17T14:30 \\
        --identifications 40 --gpu T4
    # offline, over a saved report (what the harness and the tests use):
    python3 -I scripts/characterise/billing-decompose.py --json report.json --app … --gpu T4
    python3 -I scripts/characterise/billing-decompose.py --selftest
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from typing import Any

# `modal billing rates`, 2026-11-13. Dollars per GPU-hour, by the `resource`
# label Modal's billing report uses. Kept as a literal so the script states the
# price it divided by rather than importing one it cannot show.
GPU_DOLLARS_PER_HOUR = {"A10G": 1.10, "L4": 0.80, "T4": 0.59, "A100-40GB": 2.10}

# The resource labels that are GPU time (everything else — Memory, CPU, Network
# Egress — is the warm CPU front door's cost, reported separately, never folded
# into the GPU figure).
_GPU_RESOURCES = set(GPU_DOLLARS_PER_HOUR)


def _to_float(cost: Any) -> float:
    """Billing costs arrive as strings, some in sci notation (`1.7E-7`)."""
    try:
        return float(cost)
    except (TypeError, ValueError):
        return 0.0


def decompose(
    rows: list[dict[str, Any]],
    app_substring: str,
    gpu: str,
) -> dict[str, Any]:
    """Sum a billing report's rows for the matching app into GPU vs non-GPU cost.

    ⬛ `app_substring` matches the `description` field, because an experiment
    deploys to `thestacks-vision-exp-<name>` and a caller wants that one app's
    bill, not the workspace's. A substring that matches more than one app is a
    caller error the result surfaces (`matched_apps`), not one it hides by
    summing silently.
    """
    if gpu not in GPU_DOLLARS_PER_HOUR:
        raise ValueError(f"unknown gpu {gpu!r}; known: {', '.join(GPU_DOLLARS_PER_HOUR)}")

    matched = [r for r in rows if app_substring in str(r.get("description", ""))]
    apps = sorted({str(r.get("description", "")) for r in matched})

    gpu_cost = sum(_to_float(r["cost"]) for r in matched if r.get("resource") in _GPU_RESOURCES)
    other_cost = sum(
        _to_float(r["cost"]) for r in matched if r.get("resource") not in _GPU_RESOURCES
    )

    rate_per_s = GPU_DOLLARS_PER_HOUR[gpu] / 3600.0
    gpu_seconds = gpu_cost / rate_per_s if rate_per_s else 0.0

    return {
        "app_substring": app_substring,
        "matched_apps": apps,
        "gpu": gpu,
        "rows_matched": len(matched),
        "gpu_cost_dollars": round(gpu_cost, 6),
        "gpu_seconds": round(gpu_seconds, 1),
        "non_gpu_cost_dollars": round(other_cost, 6),
    }


def per_identification(summary: dict[str, Any], n: int) -> dict[str, Any]:
    """All-in per-identification figures, valid ONLY if n is the count driven in
    the billed window. The caller asserts that; this just does the division and
    refuses a zero or negative n rather than emit an infinity."""
    if n <= 0:
        raise ValueError("identifications must be a positive count of the billed window's drives")
    return {
        "identifications": n,
        "all_in_gpu_cents_per_id": round(summary["gpu_cost_dollars"] * 100 / n, 4),
        "gpu_seconds_per_id": round(summary["gpu_seconds"] / n, 2),
        "non_gpu_cents_per_id": round(summary["non_gpu_cost_dollars"] * 100 / n, 4),
    }


def _load_rows(args: argparse.Namespace) -> list[dict[str, Any]]:
    if args.json:
        with open(args.json) as f:
            return json.load(f)
    cmd = ["modal", "billing", "report", "--show-resources", "--json"]
    if args.for_range:
        cmd += ["--for", args.for_range]
    else:
        if args.start:
            cmd += ["--start", args.start]
        if args.end:
            cmd += ["--end", args.end]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=120, check=True)
    return json.loads(out.stdout)


_SELFTEST_ROWS = [
    # Two apps in the window; the reader must isolate the target and must count
    # GPU resources only, including sci-notation and the zero-cost egress row.
    {"description": "thestacks-vision-exp-4-coldload", "resource": "T4", "cost": "0.0590"},
    {"description": "thestacks-vision-exp-4-coldload", "resource": "CPU", "cost": "0.00057"},
    {
        "description": "thestacks-vision-exp-4-coldload",
        "resource": "Network Egress",
        "cost": "1.7E-7",
    },
    {"description": "thestacks-vision-OTHER-app", "resource": "T4", "cost": "9.99"},
]


def _selftest() -> int:
    s = decompose(_SELFTEST_ROWS, "exp-4-coldload", "T4")
    # $0.0590 of T4 at $0.59/hr = exactly 360 GPU-seconds. The other app's
    # $9.99 must NOT appear, and CPU/egress must be excluded from the GPU total.
    assert s["matched_apps"] == ["thestacks-vision-exp-4-coldload"], s["matched_apps"]
    assert abs(s["gpu_seconds"] - 360.0) < 0.5, s["gpu_seconds"]
    assert abs(s["gpu_cost_dollars"] - 0.0590) < 1e-9, s["gpu_cost_dollars"]
    assert abs(s["non_gpu_cost_dollars"] - 0.00057017) < 1e-6, s["non_gpu_cost_dollars"]
    p = per_identification(s, 40)
    # 0.0590 dollars / 40 = 0.1475 cents per id; 360s / 40 = 9.0 s/id.
    assert abs(p["all_in_gpu_cents_per_id"] - 0.1475) < 1e-6, p
    assert abs(p["gpu_seconds_per_id"] - 9.0) < 1e-6, p
    # A substring matching two apps must be surfaced, not silently summed.
    multi = decompose(_SELFTEST_ROWS, "thestacks-vision", "T4")
    assert len(multi["matched_apps"]) == 2, multi["matched_apps"]
    # n must be positive.
    try:
        per_identification(s, 0)
    except ValueError:
        pass
    else:
        raise AssertionError("per_identification accepted n=0")
    print("billing-decompose selftest: OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--app", help="substring of the app's description to isolate")
    ap.add_argument("--gpu", default="T4", choices=sorted(GPU_DOLLARS_PER_HOUR))
    ap.add_argument("--start")
    ap.add_argument("--end")
    ap.add_argument("--for", dest="for_range", help="e.g. 'today' (instead of --start/--end)")
    ap.add_argument("--identifications", type=int, help="count driven in the billed window")
    ap.add_argument("--json", help="read a saved report instead of shelling modal")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return _selftest()
    if not args.app:
        ap.error("--app is required (the description substring to isolate)")

    rows = _load_rows(args)
    summary = decompose(rows, args.app, args.gpu)

    print(json.dumps(summary, indent=2))
    if len(summary["matched_apps"]) > 1:
        print(
            f"\n⚠️ {len(summary['matched_apps'])} apps matched {args.app!r} — "
            "the GPU total above sums ALL of them. Narrow --app to one.",
            file=sys.stderr,
        )
    if args.identifications is not None:
        print("\nper identification (ALL-IN for this window's arrival pattern):")
        print(json.dumps(per_identification(summary, args.identifications), indent=2))
        print(
            "\n⚠️ valid only if --identifications is the count driven in exactly "
            "the --start/--end window. This is the frontier's per-id OUTPUT to "
            "validate against, NOT its ACTIVE_S input.",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
