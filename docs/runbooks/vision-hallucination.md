# Runbook: Vision Model Hallucination (Wrong Book Identification)

**Severity:** P2 (data quality degradation — no data loss, incorrect data added)
**Owner:** Platform operator
**Last reviewed:** 2026-06-10

**Related:**
- [`modal-outage.md`](modal-outage.md) — if the vision service is failing rather than misidentifying
- [`budget-exhaustion.md`](budget-exhaustion.md) — if Modal spend is also alerting
- [`vision-service-rollback.md`](vision-service-rollback.md) — Modal-only rollback path
- [`circuit-breakers.md`](circuit-breakers.md) — `:vision_fuse` melt/reset procedure
- [ADR-001](../decisions/001-modal-over-together-ai.md) — why Modal is the inference provider
- [ADR-015](../decisions/015-vision-service-architecture.md) — current bf16 / A10G / HF Transformers stack (post-2026-05 rollback)

---

## Symptoms

**User reports:**
- "The platform identified the wrong book from my photo"
- "My upload shows the wrong title/author"
- Multiple users reporting misidentifications for the same or similar books

**Operator sees:**
- ISBN identification success rate metric dropping (alert threshold: < 90% 1-hour rolling average)
- `uploaded_images` table: `status = 'resolved'` rows where `edition_id` resolves to an unexpected book title
- User-reported false positives in support/feedback

**Distinction from a bug:** A single misidentification is expected occasionally (difficult photo, obscure book). A *pattern* of misidentifications — especially for previously-working books — indicates model drift, model update, or a systematic pre-processing issue.

---

## Impact

**Broken / Degraded:**
- Photo-based book identification accuracy for specific book categories or image conditions
- Books may have been added to the wrong user shelves (visible immediately in the UI)

**Not broken:**
- **ISBN hard gate** (CLAUDE.md core convention): no book enters the system without a verified ISBN from Open Library or Google Books. Even a hallucinated "ISBN" must pass OL/GB resolution. If the model hallucinates a non-existent ISBN, the upload is rejected (not silently accepted). Only ISBNs that resolve to real OL/GB records can cause data pollution.
- **Local OCR pre-pass** (`apps/vision/app/services/local_ocr.py`): when an image contains a clean ISBN-13 barcode, `pyzbar` decodes it and the VLM call is short-circuited entirely. Barcode decode + ISBN-13 checksum is not subject to model hallucination — these uploads are immune to this incident class.
- **Manual ISBN entry** (per US-1.1.5): always reliable, unaffected by vision model state. This is the documented user fallback when vision fails.
- All other platform features

---

## Diagnosis

### Step 1: Establish scope — how many uploads are affected?

```sql
-- Identification failure rate over the last 24 hours
SELECT
  COUNT(*) FILTER (WHERE status = 'rejected') as rejected,
  COUNT(*) FILTER (WHERE status = 'resolved') as resolved,
  COUNT(*) FILTER (WHERE status = 'pending') as pending,
  ROUND(
    COUNT(*) FILTER (WHERE status = 'rejected') * 100.0 / NULLIF(COUNT(*), 0),
    1
  ) as rejection_rate_pct
FROM op.uploaded_images
WHERE uploaded_at > NOW() - INTERVAL '24 hours';
```

Note: `rejected` means the ISBN failed Open Library / Google Books resolution (hallucinated or unreadable) — the hard gate doing its job. A high rejection rate is actually better than a high false-positive rate.

```sql
-- False positive candidates: resolved images where the user may have been misled
-- These require manual review or user reports to confirm
SELECT ui.id, ui.uploaded_at, be.isbn, b.title, b.author_id
FROM op.uploaded_images ui
JOIN op.book_editions be ON be.id = ui.book_edition_id
JOIN op.books b ON b.id = be.book_id
WHERE ui.uploaded_at > NOW() - INTERVAL '24 hours'
  AND ui.status = 'resolved'
ORDER BY ui.uploaded_at DESC
LIMIT 50;
```

### Step 2: Check if model was recently updated or redeployed

```bash
# Check Modal deployment history
modal app history thestacks-vision
```

Vision model weights are downloaded from HuggingFace at image build time (see `_download_model` in `apps/vision/modal_app.py`) and baked into the container image. A Modal redeploy after a HuggingFace model update could introduce different weights silently — the image cache is invalidated and the next build pulls whatever revision HF currently serves.

The model identifier lives in `apps/vision/modal_app.py`:
```bash
grep -n "MODEL_NAME" apps/vision/modal_app.py
```

The current baseline (post the 2026-05 rollback documented in ADR-015) is `Qwen/Qwen2.5-VL-7B-Instruct` loaded in bf16 on an A10G GPU via HF Transformers + `accelerate`. There is no commit-SHA pin today — `from_pretrained(MODEL_NAME)` resolves to HF's latest revision at image-build time. If a redeploy correlates with the regression, the most likely root cause is an upstream HF revision change.

### Step 3: Check image pre-processing pipeline

If a recent deployment changed the EXIF stripping, orientation correction, or flip detection logic:

```bash
fly logs -a thestacks-core | grep -i "orientation\|flip\|exif\|vision" | tail -50
```

The most common false positives come from:
- Mirrored images (front-facing camera selfie mode) where flip correction is missing
- Portrait/landscape orientation errors where orientation normalisation is missing
- Low-resolution or heavily cropped images

Also check whether the local OCR pre-pass is short-circuiting as expected. If recent changes to `apps/vision/app/services/local_ocr.py` regressed the barcode decode path, every barcode-bearing image now reaches the VLM (which is more hallucination-prone for barcode decoding than `pyzbar`):

```bash
fly logs -a thestacks-core | grep -i "local_ocr\|barcode\|pyzbar" | tail -50
```

### Step 3b: Check vision telemetry

`Stacks.AI.Client` emits `[:stacks, :vision, :request, :start | :stop | :exception]` (see `apps/core/lib/stacks/ai/client.ex`). Plot `:stop` events grouped by endpoint (`classify` vs `extract`) and by returned confidence — a sudden distribution shift towards high confidence on extracts that subsequently fail OL/GB resolution is the canonical hallucination signature.

### Step 4: Run the resolver eval (the only harness that exists)

```bash
# From project root
just run mix eval.resolver
```

This replays a recorded corpus (`apps/core/priv/eval/corpus.exs`) through the
candidate scorer and exits 1 on a regression against pinned expectations. Note
what it does NOT do: it evaluates the **resolver's ranking**, not the vision
model's accuracy, and its corpus holds recorded OL/GB metadata and VLM signals
rather than images. **There is no vision-accuracy harness yet**, so this step
cannot confirm model drift — it can only tell you whether ranking behaviour
changed. Treat a clean run here as silence, not as evidence the model is fine.

### Step 5: Sample recent resolved uploads for manual review

```bash
fly ssh console -a thestacks-core
```
```elixir
# Sample recent resolved uploads + the edition they resolved to.
iex> import Ecto.Query
iex> Stacks.Repo.all(
...>   from ui in Stacks.Books.UploadedImage,
...>     where: ui.status == "resolved" and ui.uploaded_at > ago(24, "hour"),
...>     order_by: [desc: ui.uploaded_at],
...>     limit: 20,
...>     preload: [book_edition: :book]
...> )
# Review whether the resolved books match what users likely intended.
```

---

## Response

### Immediate (if hallucination rate is high)

**Option A: Tighten the verification UX**

The upload flow already has a verification step ("We think this is…"). If users are skipping it too quickly, the right lever is a frontend / product change — there is no env-var toggle for "non-skippable confirmation" today. File a frontend issue rather than reaching for runtime config.

**Option B: Disable vision by melting `:vision_fuse`**

The vision service has no `AI_ENABLED` kill-switch. The supported way to take vision offline is to melt the circuit breaker — once blown, `Stacks.AI.Client.call_vision/2` returns `{:error, :circuit_open}`, Oban vision jobs see the error and snooze with backoff, and the upload flow falls back to manual ISBN entry (the documented US-1.1.5 fallback).

```bash
fly ssh console -a thestacks-core
```
```elixir
iex> :fuse.melt(:vision_fuse)
iex> :fuse.ask(:vision_fuse, :sync)   # => :blown
```

Note: `Stacks.CircuitBreakers` actively probes blown fuses every 15 seconds and will reset `:vision_fuse` as soon as the upstream looks healthy (see `circuit-breakers.md`). For a deliberate, sustained shutdown — e.g. while investigating a hallucination incident — disable the probe by stopping the vision Modal app instead:

```bash
modal app stop thestacks-vision
```

Re-enabling: `modal deploy apps/vision/modal_app.py`, then `:fuse.reset(:vision_fuse)` from a core console.

### If the model was redeployed with an updated version

The model identifier is `MODEL_NAME` in `apps/vision/modal_app.py` and is consumed by `_download_model` at image-build time. There is no commit-SHA pin today; both `AutoProcessor.from_pretrained` and `Qwen2_5_VLForConditionalGeneration.from_pretrained` resolve to HF's latest revision.

1. Identify the last known-good Modal deploy (`modal app history thestacks-vision`) and its commit SHA in this repo.
2. Pin by adding a `revision=` kwarg to both `from_pretrained` calls inside `_download_model` and `VisionModel.load`:
   ```python
   # apps/vision/modal_app.py
   MODEL_NAME = "Qwen/Qwen2.5-VL-7B-Instruct"
   MODEL_REVISION = "abc1234..."  # known-good HF commit SHA

   AutoProcessor.from_pretrained(MODEL_NAME, revision=MODEL_REVISION)
   Qwen2_5_VLForConditionalGeneration.from_pretrained(
       MODEL_NAME, revision=MODEL_REVISION, torch_dtype="bfloat16"
   )
   ```
3. Redeploy the vision service:
   ```bash
   modal deploy apps/vision/modal_app.py
   ```
4. Monitor identification accuracy for 1 hour after redeploy.

If the prompts themselves are suspected (e.g. a recent edit to `_CLASSIFY_PROMPT` or `_EXTRACT_PROMPT` in `modal_app.py`), revert that commit before re-deploying. These are the only two prompts in the post-rollback stack — there is no `_ANALYZE_PROMPT` or `_VERIFY_PROMPT` (those belonged to the reverted vLLM stack; see ADR-015's 2026-05 rollback note).

### If image pre-processing changed

1. Identify the commit that changed the pre-processing pipeline.
2. Test with known problem images (build a small corpus of mirrored/rotated photos).
3. Revert the pre-processing change if it caused the regression.

---

## Recovery

**After disabling vision (`:vision_fuse` melted and/or Modal app stopped):**
- Redeploy the vision service if it was stopped: `modal deploy apps/vision/modal_app.py`
- Reset the fuse from a core console:
  ```elixir
  iex> :fuse.reset(:vision_fuse)
  iex> :fuse.ask(:vision_fuse, :sync)   # => :ok
  ```
- Oban vision queue resumes automatically as soon as `Stacks.AI.Client.call_vision/2` stops returning `{:error, :circuit_open}`.

**Correcting false-positive shelved books:**
- There is no automated recovery path for books that were incorrectly shelved.
- Users must manually remove incorrect books and add the correct ones.
- If the platform has a feedback mechanism, monitor for user reports of incorrect identifications.

**Verify accuracy recovery:**

There is no accuracy harness to run — see Step 4. Recovery has to be judged from
live signal instead: watch the vision telemetry distribution from Step 3b return
to its normal shape, and sample recent resolved uploads (Step 5) until
identifications look right again. Record what you sampled and what you saw, so
the next responder inherits evidence rather than a memory.

---

## Post-Incident

- Record the sampled evidence showing the regression and the recovery.
- If a model update caused the drift: implement commit SHA pinning (tracked in Issue #005 benchmark framework).
- If a pre-processing bug caused the issue: add regression tests for the specific image condition that triggered it.
- Update the benchmark corpus with examples of images that caused false positives.
- Consider raising the minimum Jaro-Winkler threshold (currently 0.8) for the title/author cross-reference check if false positives are passing the validation step.
