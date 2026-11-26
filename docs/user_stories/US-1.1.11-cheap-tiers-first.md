# US-1.1.11 — The Cheap Tiers Answer First

## 1. User Story

> **As a** reader photographing a book, **I want** the platform to try its fast, cheap recognisers
> before waking the expensive one **so that** the common case answers in seconds and the money
> goes where the hard photographs are.

**Why this is a user story and not just tooling.** The reader feels this as latency and the
platform owner feels it as the monthly bill: a barcode photo that answers in six seconds instead
of thirty, a GPU that sleeps through a quarter of uploads. The order of tiers is a product
promise about both.

**Acceptance criteria:**
- A decodable barcode answers without any GPU dispatch; its checksum makes the answer final.
- A cover-text read NEVER answers on its own — a read is evidence, not an identification —
  until an acceptance design can tell a partial title from the book itself.
- A rejected identification escalates: the retry never re-offers the tier that just failed.
- Non-book photographs still meet the classify guard; no CPU path may bypass rejection.
- The cascade's accuracy is gated per-stratum against the recorded reference; the cheap tiers
  may only add speed, never subtract correctness.

## 2. Interaction Flow

No new UI; the flow is the upload loop's internals:

1. `POST /api/upload` → `IdentifyBookJob` → `Stacks.Moderation.run_pipeline/1`.
2. Flag `:cpu_first_identification` (default on): one `cpu_only` call to the sidecar — barcode
   scan + cover-text read, no GPU.
3. A checksum'd barcode resolves through the existing seam and is FINAL.
4. Anything else (and any retry carrying exclusions) runs the full analyze: classify guard,
   then extract, GPU on one dispatch.
5. The read rides along as `ocr_attempt` for the shadow measurement either way.

## 3. Current State (delivered, measured)

- Shipped 2026-11-19/20 on this branch; cascade eval (`mix eval.cascade`, run 5): **91/122**
  vs the sidecar's 84/122 and the 7B reference's 86/122 — no non-conceded stratum below the
  reference; negatives 20/20; 34 of 122 answers (28%) never woke the GPU.
- The cover-text tier was measured NET-NEGATIVE as a final-answer tier (clear_cover 22/22 →
  6/22; three negatives identified as books) and demoted to shadow behind
  `:cpu_title_resolution` — its return is gated on an acceptance design, with the illegible
  rescue (1/10 → 8/10) living in core's resolution layer and therefore kept.
- Rejection escalation: `Stacks.Moderation` skips the whole CPU pass when exclusions are
  present ("a rejection is a miss").

## 4. Validation

- `apps/core/test/stacks/moderation_cpu_first_test.exs` (tier order, escalation, default-off
  title tier — each mutation-probed).
- `mix eval.cascade` per-stratum against `priv/eval/vision_baseline_7b_reference.json`.
