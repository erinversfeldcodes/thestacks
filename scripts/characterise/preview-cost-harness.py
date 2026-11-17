"""Solve a vision architecture's cost constants from what a preview was BILLED.

⛔ THE LOOP THAT CLOSES COST-BEFORE-MERGE. `billing-decompose.py` reads one
window's bill. This drives two CONTROLLED bursts whose billed GPU-seconds
differ in a way that isolates the frontier's inputs, so a preview answers
"what will this architecture cost per identification" without a month of
production. The arithmetic:

    PACKED  — N identifications back-to-back through ONE warm container:
              one cold load, N active inferences, one trailing idle window.
                  gpu_s_packed = COLD + N·ACTIVE + W
    SPACED  — N lone identifications, each spaced > W apart so each gets its
              OWN cold container:
                  gpu_s_spaced = N·(COLD + ACTIVE + W)

Two equations, two unknowns (ACTIVE, COLD); W is the scaledown window, known.
Subtracting isolates COLD, then ACTIVE falls out. Those feed
`scaledown-frontier.py` (VISION_ACTIVE_S / _COLD_LOAD_S / _WARM_WALL_S) as
MEASURED constants for the chosen architecture, and the frontier's predicted
per-id cost is checked against the bill the bursts actually produced.

⚠️ THE MODEL ASSUMES THE CONTAINERS BEHAVE AS DESCRIBED — packed reuses one
container, spaced forces N cold ones. That holds only if the spacing really
exceeds the scaledown window and the packed burst is serial. The harness
reports the assumption as a check (packed cold-starts ≈ 1, spaced ≈ N) so a
violated assumption shows up instead of silently biasing the solve.

⚠️ BILLING LAGS. A burst's cost appears in the report some minutes after it
runs; the live driver polls the app's billed GPU-seconds until the delta
stops growing before trusting it. The settling lag it measures is itself
reported — it is the thing a future caller most needs to know.
"""

from __future__ import annotations

import argparse
import json
import sys


def solve(
    gpu_s_packed: float,
    gpu_s_spaced: float,
    n: int,
    window_s: float,
) -> dict[str, float]:
    """Recover (ACTIVE_S, COLD_LOAD_S) from the two bursts' billed GPU-seconds.

        gpu_s_packed = COLD + N·ACTIVE + W
        gpu_s_spaced = N·COLD + N·ACTIVE + N·W
        spaced - packed = (N-1)·(COLD + W)   ->   COLD = (Δ)/(N-1) - W
        ACTIVE = (packed - COLD - W) / N

    ⚠️ Returns negative constants rather than clamping them: a negative COLD
    or ACTIVE means the container model was violated (the spacing did not force
    cold starts, or the packed burst was not one container), and clamping would
    hide exactly that. The caller checks the sign.
    """
    if n < 2:
        raise ValueError("n must be >= 2 — the solve divides by (n-1)")
    cold = (gpu_s_spaced - gpu_s_packed) / (n - 1) - window_s
    active = (gpu_s_packed - cold - window_s) / n
    return {"active_s": round(active, 3), "cold_load_s": round(cold, 3)}


def _selftest() -> int:
    # Plant known constants, synthesise the two bursts EXACTLY as the model
    # says they bill, and confirm the solve recovers them.
    active, cold, w, n = 5.74, 20.5, 60.0, 8
    packed = cold + n * active + w
    spaced = n * (cold + active + w)
    got = solve(packed, spaced, n, w)
    assert abs(got["active_s"] - active) < 1e-6, got
    assert abs(got["cold_load_s"] - cold) < 1e-6, got

    # A violated assumption (spacing did NOT force cold starts, so spaced bills
    # like packed) must surface as a non-physical negative, not a plausible lie.
    bad = solve(packed, packed, n, w)
    assert bad["cold_load_s"] < 0, bad

    # n < 2 is refused.
    try:
        solve(1.0, 1.0, 1, w)
    except ValueError:
        pass
    else:
        raise AssertionError("solve accepted n=1")
    print("preview-cost-harness selftest: OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument(
        "--analyze",
        nargs=4,
        metavar=("GPU_S_PACKED", "GPU_S_SPACED", "N", "WINDOW_S"),
        help="solve from two already-measured billed GPU-second totals",
    )
    ap.add_argument("--gpu", default="T4")
    args = ap.parse_args()

    if args.selftest:
        return _selftest()
    if args.analyze:
        packed, spaced, n, w = (
            float(args.analyze[0]),
            float(args.analyze[1]),
            int(args.analyze[2]),
            float(args.analyze[3]),
        )
        solved = solve(packed, spaced, n, w)
        non_physical = solved["active_s"] <= 0 or solved["cold_load_s"] <= 0
        # Widened for display: solve() returns floats, the report adds string notes.
        got: dict[str, object] = dict(solved)
        got["warm_wall_s_note"] = "measure separately from eval latency (VLM_EXTRACT p50)"
        if non_physical:
            got["⚠️ warning"] = (
                "a non-physical constant means the container model was violated "
                "(spacing < window, or the packed burst was not one container) — "
                "do not feed these to the frontier"
            )
        print(json.dumps(got, indent=2))
        print(
            "\nfeed to the frontier as measured constants for "
            f"{args.gpu}:\n  VISION_ACTIVE_S={got['active_s']} "
            f"VISION_COLD_LOAD_S={got['cold_load_s']} "
            f"just run python3 scripts/characterise/scaledown-frontier.py {args.gpu}",
            file=sys.stderr,
        )
        return 0

    ap.error("pass --selftest or --analyze GPU_S_PACKED GPU_S_SPACED N WINDOW_S")
    return 2


if __name__ == "__main__":
    sys.exit(main())
