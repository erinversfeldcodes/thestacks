# US-1.1.12 — The GPU Sleeps When Nobody Is Uploading

## 1. User Story

> **As the** platform owner funding a hobby-scale service, **I want** the vision GPU to scale to
> zero between uploads, with its idle tail measured from bills rather than configuration,
> **so that** the service costs tens of dollars a month and I can prove it.

**Acceptance criteria:**
- The GPU class scales to zero; the scaledown window is a recorded, re-derivable decision.
- The cost model's constants come from what the provider BILLED, not from estimates — and the
  effective idle tail is the billed one, not the configured one.
- A cold start is accepted physics with an honest UX (see US-1.1.14), not fought with
  keep-warm spend.

## 2. Flow (a configuration and a measurement loop)

1. `apps/vision/modal_app.py`: `scaledown_window=60`, T4 + Qwen3-VL-4B fp16 defaults.
2. The measurement loop: `scripts/characterise/drive-cost-burst.py` (one pattern per DEDICATED
   Modal app, because billing is day-bucketed per app) → `billing-decompose.py` →
   `preview-cost-harness.py --analyze` → `scaledown-frontier.py`.

## 3. Current State (delivered, measured 2026-11-20)

- Billed constants at T4+4B, post-single-dispatch: ACTIVE ≈ 14.7 s/id, COLD_LOAD ≈ 23 s.
- ⚠️ **The configured 60 s window bills ≈ 91 s of effective tail** (both burst patterns agree;
  it also explains observed containers surviving 90 s idle gaps). A lone cold identification
  bills ≈ 2.1¢; the frontier's monthly rows need the billed window before they are honest —
  tracked in the gate child's notes as the frontier re-derivation.

## 4. Validation

- The burst→bill→solve loop above, re-runnable per architecture; its headers carry the
  day-bucket and app-isolation semantics that make the numbers mean something.
