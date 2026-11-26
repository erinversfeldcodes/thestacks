# Vision service cost audit — 2026-11-17

> **Scope:** the vision identification service (Modal GPU + CPU front door) — the
> only material inference cost on the platform. $50/month total inference budget.
> **Basis:** MEASURED, not projected. Every figure traces to a tool and a run,
> not a rate-card estimate. The method itself is the audit's main contribution:
> cost is now measurable on a **preview before merge**, not after a month of
> production (the premise W8a started from and discarded).
> **Supersedes for vision:** the per-user projection in `docs/capacity-model.md` §3,
> which predates any measurement. Update that doc to point here.

---

## 1. How these numbers were obtained (so they can be re-run, not trusted)

| instrument | what it measures | file |
|---|---|---|
| idle/active decomposition | GPU-active vs idle-tail per identification | `scripts/characterise/vision-cost-decomposition.py` (eval artefacts) |
| scaledown frontier | $/month and p95 across arrival rates and windows | `scripts/characterise/scaledown-frontier.py` (env-overridable per architecture) |
| billing decompose | ACTUAL billed GPU-seconds for an app/window | `scripts/characterise/billing-decompose.py` (`modal billing report --json`) |
| preview cost harness | solves ACTIVE_S / COLD_LOAD_S from a packed+spaced billing burst | `scripts/characterise/preview-cost-harness.py` |

⬛ **The loop that closes "cost before merge":** deploy a config to a preview →
drive a controlled burst (`slo-load.sh` / direct Modal client) → read what Modal
actually billed (`billing-decompose`) → solve the constants (`preview-cost-harness`)
→ predict $/month at each arrival rate (`scaledown-frontier`). The prediction is
checked against the bill the burst produced; a gap is the model's error, measured.

---

## 2. The cost is wake-ups, not inference

- A lone identification is ~**9.34c**, of which **98.1% is idle GPU** after the
  model answers (at the former 300s window; since cut to 60s). Actual inference
  is ~0.2c.
- At hobby traffic (~12–48 uploads/day) the container is **cold for 94–99% of
  requests** — the system is expensive *because* it is quiet. Cost per
  identification FALLS as volume rises (a busy container amortises one idle tail
  across many identifications).
- ⬛ Consequence that governs every lever: a change that reduces how OFTEN the
  GPU wakes beats any change to its hourly rate, and the two compound.

---

## 3. The adopted architecture, measured — T4 + Qwen3-VL-4B

Measured live via the preview cost harness (packed+spaced billing solve, 2026-11-17):

| constant | value | note |
|---|---|---|
| COLD_LOAD_S | **24.98s** | clean; matches an independent 26s cold-wall. Boot-dominated (~15s), not weight-load (~4s) |
| ACTIVE_S | 9.50s | ⚠️ upper bound — inflated by sequential-driving inter-call idle; real is lower, so costs here are CONSERVATIVE |
| model fit | EXACT | `COLD + 6·ACTIVE + 60 = 142.0` = measured packed GPU-seconds, to the decimal |

**$/month at the 60s window (scaledown-frontier at the measured constants):**

| load | $/month | within $50? |
|---|---:|---|
| 12 uploads/day | ~$9 | yes |
| **48/day** | **$21.98** | yes |
| 120/day | ~$35 | yes |
| ~60–100/day | — | **the budget ceiling** |
| 240/day | >$66 | no |

vs the 7B/A10G baseline's **$37.60** at 48/day — a **42% cut**, tracking the
−46% GPU rate delta (A10G $1.10/hr → T4 $0.59/hr). The architecture's cost
promise holds in *billed reality*, not just on the rate card.

**Rates (`modal billing rates`, 2026-11-13):** A10G $1.10/hr · L4 $0.80 · T4 $0.59.

---

## 4. The scaledown window

**60s, kept.** At hobby scale it costs $9–22/mo (within budget); a longer window
buys down the ~94% cold rate only marginally (+$13/mo for 120s) and is not worth
it at this traffic. See ADR 026 §8. ⚠️ The window does NOT help p95 — at hobby
traffic almost every lone request is cold, so p95 ≈ 32.6s regardless; that is a
responsiveness matter (the async affordance), not a cost one.

## 5. R0 — single dispatch (cost side)

A book identification used to make TWO GPU dispatches (classify + extract); the
harness drove classify-only, so §3's per-id cost is a single-dispatch figure and
real book cost ran higher by ~one forward pass. R0 (now the default,
`single_dispatch`) collapses them to one dispatch on one container, clawing most
of that back and removing a rare second-cold-start.

---

## 6. Budget posture and what to watch

- **Headroom:** at the expected 12–48 uploads/day, spend is $9–22/mo against the
  $50 ceiling — comfortable. The unavoidable base (every upload a cold
  identification) is ~$7.5/mo at 1,440/day.
- **Ceiling:** ~60–100 uploads/day is where the 60s window first exceeds $50.
  Past it, no window setting stays in budget on T4+4B — the lever then is the
  CPU-first path (fewer GPU wakes), not hardware.
- **Caps (W8c):** the per-provider spend guard (`Stacks.AI.Budget`) enforces a
  daily and monthly ceiling from the durable ledger. Making those caps
  env-configurable with a pre-breach alert is W8c (this wave).
- ⚠️ **What this audit can NOT settle:** the real arrival-rate *distribution* —
  there is no production telemetry. Every $/month here is a band read at an
  assumed arrival rate; production pins which column of the frontier we sit in.
  That is the one input a preview genuinely cannot supply, and the frontier
  already brackets it rather than guessing.

---

## 7. Re-running this audit

```sh
# measured per-architecture cost, from a preview burst:
VISION_GPU=T4 VISION_MODEL_NAME=Qwen/Qwen3-VL-4B-Instruct … <deploy to a preview app>
just run python3 scripts/characterise/billing-decompose.py --app <app> --gpu T4 --identifications N
just run python3 scripts/characterise/preview-cost-harness.py --analyze <packed> <spaced> <N> 60 --gpu T4
VISION_ACTIVE_S=… VISION_COLD_LOAD_S=… just run python3 scripts/characterise/scaledown-frontier.py T4
```
