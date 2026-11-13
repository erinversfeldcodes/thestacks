#!/usr/bin/env python3
"""What the GPU scaledown window costs, and what it buys back in latency.

⛔ THE WINDOW IS THE LARGEST COST LEVER IN THE SYSTEM AND IT IS ONE LITERAL.
Measurement put a lone identification at 9.34c, of which **98.1% is a GPU
sitting idle** after answering. Halving the model's inference time saves 1%;
cutting the window from 300s to 60s saves 78%. Any cost work aimed at making
inference faster is aimed at the wrong term.

⚖️ THE TRADE IS LATENCY, AND IT IS REAL. A shorter window means more requests
arrive to find no container up, and a cold start costs ~20.5s of model load
before any inference happens. So this is not a free saving — it is money
against p95, and the exchange rate depends entirely on how often readers
upload.

⚠️ WHICH IS THE ONE INPUT THIS CANNOT MEASURE. The eval corpus says nothing
about arrival times, and there is no production telemetry yet. So the frontier
is computed ACROSS a range of arrival rates rather than at one: the output is a
band, and picking a point on it requires either real traffic or a stated
assumption that someone owns.

Simulated rather than solved in closed form: the busy-period algebra for an
M/G/1-style container with a hold-down timer is easy to get subtly wrong, and a
simulation is checkable by reading it.
"""

from __future__ import annotations

import random
import statistics
import sys

# ── Measured inputs. Every one of these came off a deployed stack. ───────────

# GPU-active seconds per identification: 226.9s over 40 identifications.
ACTIVE_S = 5.74

# Model load on a cold container, from the W6c cold identification. Billed as
# GPU time AND paid by the reader as latency — it is the whole cost of a miss.
COLD_LOAD_S = 20.5

# Wall-clock a reader waits on a WARM container: VLM_EXTRACT p50.
WARM_WALL_S = 9.745

# `modal billing rates`, 2026-11-13.
RATE_PER_S = {"A10G": 1.10 / 3600, "L4": 0.80 / 3600, "T4": 0.59 / 3600}

MONTHLY_BUDGET_CENTS = 50 * 100


def simulate(
    window_s: float,
    arrivals_per_hour: float,
    rate_per_s: float,
    hours: float = 720.0,
    seed: int = 7,
) -> dict[str, float]:
    """One month of Poisson arrivals against a container with a hold-down timer.

    ⬛ The container is billed from the moment it starts until `window_s` after
    its LAST request — which is why requests that arrive close together are
    cheap and an isolated one pays for the whole window by itself.
    """
    rng = random.Random(seed)
    lam = arrivals_per_hour / 3600.0
    if lam <= 0:
        raise ValueError("arrival rate must be positive")

    t = 0.0
    horizon = hours * 3600.0

    # ⛔ BILLED TIME IS A CONTAINER LIFETIME, NOT A SUM OVER REQUESTS. An
    # earlier version accumulated per request and added the window under a
    # condition that was never true, so the window went unbilled entirely —
    # and the result was 11x too optimistic against the measured lone
    # identification. Modal bills from the moment a container starts until it
    # scales down; tracking that interval directly is the only shape that
    # cannot lose a term.
    container_start: float | None = None
    container_end = -1.0
    billed_s = 0.0
    cold = 0
    waits: list[float] = []
    n = 0

    while True:
        t += rng.expovariate(lam)
        if t > horizon:
            break
        n += 1

        if t >= container_end:
            # Nothing is up. Close the previous lifetime and start a new one.
            if container_start is not None:
                billed_s += container_end - container_start
            cold += 1
            container_start = t
            container_end = t + COLD_LOAD_S + ACTIVE_S + window_s
            waits.append(COLD_LOAD_S + WARM_WALL_S)
        else:
            # Warm: the hold-down restarts from this request's completion.
            container_end = t + ACTIVE_S + window_s
            waits.append(WARM_WALL_S)

    # The final container's lifetime is billed like any other.
    if container_start is not None:
        billed_s += container_end - container_start

    cents = billed_s * rate_per_s * 100

    waits.sort()
    p95 = waits[min(round(0.95 * (len(waits) - 1)), len(waits) - 1)] if waits else 0.0

    return {
        "identifications": n,
        "cold_rate": cold / n if n else 0.0,
        "cents_total": cents,
        "cents_each": cents / n if n else 0.0,
        "p50_wait_s": statistics.median(waits) if waits else 0.0,
        "p95_wait_s": p95,
    }


def main() -> int:
    gpu = sys.argv[1] if len(sys.argv) > 1 else "A10G"
    if gpu not in RATE_PER_S:
        sys.exit(f"unknown GPU {gpu!r}; known: {', '.join(RATE_PER_S)}")
    rate = RATE_PER_S[gpu]

    print(f"\nscaledown frontier on {gpu} (${rate * 3600:.2f}/hour), one simulated month")
    print("⚠️ arrival rate is ASSUMED — there is no production telemetry. Read the band.\n")

    windows = [30, 60, 120, 300, 600]
    for aph in (0.5, 2, 10, 60):
        print(f"── {aph:g} identifications/hour  (~{aph * 24:,.0f}/day)")
        print(
            f"   {'window':>7}{'cold':>8}{'per id':>9}{'month':>10}"
            f"{'p50 wait':>10}{'p95 wait':>10}   within $50?"
        )
        for w in windows:
            r = simulate(w, aph, rate)
            ok = "yes" if r["cents_total"] <= MONTHLY_BUDGET_CENTS else "NO"
            print(
                f"   {w:>5}s{r['cold_rate']:>8.0%}{r['cents_each']:>8.2f}c"
                f"{r['cents_total'] / 100:>9.2f}${r['p50_wait_s']:>9.1f}s"
                f"{r['p95_wait_s']:>9.1f}s   {ok}"
            )
        print()

    print("⛔ A cold start costs the reader ~30s of wall time against ~10s warm.")
    print("   That is the exchange rate: every point of cold-start rate buys back")
    print("   window seconds, and sells p95.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
