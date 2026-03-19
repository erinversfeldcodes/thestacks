# Runbook: Vision Model Hallucination (Wrong Book Identification)

**Severity:** P2 (data quality degradation — no data loss, incorrect data added)
**Owner:** Platform operator
**Last reviewed:** 2026-03-19

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
- The ISBN hard gate: even a hallucinated "ISBN" must pass Open Library resolution. If the model hallucinates a non-existent ISBN, the upload is rejected (not silently accepted). Only ISBNs that resolve to real Open Library records can cause data pollution.
- Manual ISBN entry: always reliable, unaffected by vision model state
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
FROM uploaded_images
WHERE uploaded_at > NOW() - INTERVAL '24 hours';
```

Note: `rejected` means the ISBN failed Open Library resolution (hallucinated or unreadable). A high rejection rate is actually better than a high false-positive rate — the hard gate is working.

```sql
-- False positive candidates: resolved images where the user may have been misled
-- These require manual review or user reports to confirm
SELECT ui.id, ui.uploaded_at, be.isbn, b.title, b.author_id
FROM uploaded_images ui
JOIN book_editions be ON be.id = ui.edition_id
JOIN books b ON b.id = be.book_id
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

Vision model weights are downloaded from HuggingFace at deploy time. A Modal redeploy after a HuggingFace model update could introduce different weights silently.

Check the pinned model version in `apps/vision/app/config.py`:
```bash
grep -n "model_name\|commit_sha" apps/vision/app/config.py
```

If no commit SHA is pinned, the model version may have changed.

### Step 3: Check image pre-processing pipeline

If a recent deployment changed the EXIF stripping, orientation correction, or flip detection logic:

```bash
fly logs -a thestacks-core | grep -i "orientation\|flip\|exif\|vision" | tail -50
```

The most common false positives come from:
- Mirrored images (front-facing camera selfie mode) where flip correction is missing
- Portrait/landscape orientation errors where orientation normalisation is missing
- Low-resolution or heavily cropped images

### Step 4: Run the benchmark suite (if available)

```bash
# From project root — requires corpus from Issue #005
just benchmark
```

This runs the vision evaluation harness against the known-good corpus in `apps/vision/benchmark/`. If accuracy has dropped significantly from the baseline, it confirms model drift.

### Step 5: Sample recent resolved uploads for manual review

```bash
fly ssh console -a thestacks-core
```
```elixir
# Get recent resolved uploads with their extracted ISBNs
iex> Stacks.Books.recent_resolved_uploads(limit: 20)
# Review whether the resolved books match what users likely intended
```

---

## Response

### Immediate (if hallucination rate is high)

**Option A: Enable mandatory verification for all uploads**

The upload flow already has a verification step by default ("We think this is…"). If users are skipping this step too quickly, tighten the UX rather than the model.

If the model is returning high-confidence incorrect results, the operator can set an environment variable to require explicit user confirmation even for high-confidence identifications:

```bash
fly secrets set REQUIRE_MANUAL_CONFIRM=true -a thestacks-core
```

This makes the verification step non-skippable even in bulk upload mode.

**Option B: Disable vision entirely, require manual ISBN entry**

```bash
fly secrets set AI_ENABLED=false -a thestacks-core
```

This disables all AI calls. Oban vision jobs snooze. Users are directed to manual ISBN entry. Manual ISBN entry is the reliable fallback — the platform works correctly without vision.

### If the model was redeployed with an updated version

1. Check the current model version in `apps/vision/app/config.py`
2. If no commit SHA is pinned, pin immediately to the last known-good commit:
   ```python
   # apps/vision/app/config.py
   model_name = "Qwen/Qwen2.5-VL-7B-Instruct"
   model_commit_sha = "abc1234..."  # Pin to last known-good
   ```
3. Redeploy the vision service:
   ```bash
   modal deploy apps/vision/modal_app.py
   ```
4. Monitor identification accuracy for 1 hour after redeploy.

### If image pre-processing changed

1. Identify the commit that changed the pre-processing pipeline.
2. Test with known problem images (build a small corpus of mirrored/rotated photos).
3. Revert the pre-processing change if it caused the regression.

---

## Recovery

**After disabling vision (`AI_ENABLED=false`):**
- Re-enable after root cause is identified and fixed:
  ```bash
  fly secrets set AI_ENABLED=true -a thestacks-core
  ```
- Oban vision queue will resume automatically.

**Correcting false-positive shelved books:**
- There is no automated recovery path for books that were incorrectly shelved.
- Users must manually remove incorrect books and add the correct ones.
- If the platform has a feedback mechanism, monitor for user reports of incorrect identifications.

**Verify accuracy recovery:**
```bash
just benchmark
```

Review the `apps/vision/benchmark/reports/` output — ISBN recall and classification F1 scores should return to baseline.

---

## Post-Incident

- Commit the benchmark run results showing the regression and the recovery.
- If a model update caused the drift: implement commit SHA pinning (tracked in Issue #005 benchmark framework).
- If a pre-processing bug caused the issue: add regression tests for the specific image condition that triggered it.
- Update the benchmark corpus with examples of images that caused false positives.
- Consider raising the minimum Jaro-Winkler threshold (currently 0.8) for the title/author cross-reference check if false positives are passing the validation step.
