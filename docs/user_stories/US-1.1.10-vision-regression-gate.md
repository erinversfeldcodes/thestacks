# US-1.1.10 — Notice When Book Recognition Gets Worse

## 1. User Story

> **As a** reader who photographs books to shelve them, **I want** the platform to notice when its
> recognition gets worse **so that** a quiet regression does not turn my uploads into failures
> nobody was watching for.

**Why this is a user story and not just tooling.** The reader never runs the eval and never sees
its output. But the thing it protects is the core loop: point a camera at a book and have it land
on a shelf. A vision model can degrade for reasons that have nothing to do with this codebase — a
dependency bump, a different GPU, a changed prompt — and every unit test in the repository would
stay green while the product got worse. The reader would find out first, which is the wrong order.

**Acceptance criteria:**
- Every image in the corpus is scored against a label, through the same call the upload path makes.
- A drop against the recorded baseline fails, loudly, naming what regressed.
- A run that could not happen is never reported as a pass.
- No real user upload is ever added to the corpus.

## 2. Interaction Flow

There is no UI. The flow is a run:

1. `mix eval.vision` loads `priv/eval/vision_corpus.exs`.
2. Each image is posted to the deployed vision service through
   `Stacks.AI.Client.call_vision("analyze", %{image: b64})` — the production seam.
3. Each answer is scored: does the classification match the label, and where an ISBN is expected,
   is it among the returned candidates.
4. The total is compared against `priv/eval/vision_baseline.json`.

### Sad paths
- **No service configured** → SKIPS with `"This is not a pass."` on stdout. Exits 0 only because
  *not run* is not *regressed*.
- **A caller needs it enforced** → `EVAL_VISION_REQUIRED=1` turns that skip into a failure.
- **Score below baseline** → fails, quoting the score and the baseline.

## 3. The corpus, and the constraint on it

Six committed fixtures: a clean barcode, a negative (`not_a_book`), two hostile orientations, an
occlusion, and text clutter. The negative is as load-bearing as the positives — a model that
answers "yes, a book" to everything scores perfectly on books alone.

⛔ **No real user upload may ever be added.** Not a sample, not "just the ones that failed", not
with consent bolted on afterwards. A reader photographing a bookshelf may capture other people who
never consented to being processed by a vision model, those people cannot be asked, and a corpus is
forever. Every fixture is owner-authored or synthetic. See `docs/vision-eval-corpus-plan.md`.

## 4. Why no-regression rather than a threshold

On six samples every observation moves the score by 16.7 points. An "≥90% accuracy" gate would fire
on one image changing its mind — and the first time it went red for a benign reason, someone would
raise the threshold rather than investigate, which is how a gate becomes decoration.

`docs/vision-eval-corpus-plan.md` specifies the ~120-image corpus (15–20 per stratum, mirroring the
cascade) at which per-stratum absolute thresholds become defensible. Expanding to it is deferred to
Phase 2, deliberately.

## 5–11. Database, Events, Jobs, Storage, Cache, dbt

**None.** The eval reads image files from the repository and calls one external service.

## 8. External Services

- **Service**: Modal — the deployed vision app (`thestacks-vision`, function `vision_api`).
- **Client**: `Stacks.AI.Client`, through the same fuse and budget checks as production traffic.
- **Endpoint**: `/analyze`, matching `Stacks.Moderation`'s call exactly.

## Baseline

**6/6**, recorded 2026-08-20 against the live service.

Getting there caught a mislabel rather than a model fault: the corpus expected ISBN
`9780061470769` for the barcode fixture, the model returned `9780156001311`, and Open Library
settles it — `9780156001311` is *The Name of the Rose*, which is what that image shows, while
`9780061470769` is *Bird Lake Moon*, a different book that appears only in the manual-ISBN-entry
specs. The corpus plan had conflated the two and the error was copied into the corpus. **The model
was right and the label was wrong**, which is the failure mode an eval has to be able to survive:
a baseline recorded against a bad label pins the wrong expectation forever.

## The caller

`scripts/deploy-stack.sh`, immediately after the Modal deploy succeeds and the service URL is
resolved — with `EVAL_VISION_REQUIRED=1`, so a run that cannot happen fails rather than skipping.

That moment is the cheap one: the new image is live, nothing depends on it yet, and the **core app
has not been deployed against it**. A regression stops the pipeline before the rest of the stack
rolls forward onto a model that got worse.

No database is required. The task boots the app, but Ecto retries an unreachable repo in the
background rather than failing the boot — verified by running the eval against a `DATABASE_URL`
pointing at a dead port, which still scored 6/6. So the gate runs the same whether or not the
deploying machine can reach Postgres.

Both failure modes are proven:

| Probe | Result |
|---|---|
| Baseline raised above what the model scores | exit **1** — `REGRESSION — scored 6/6, baseline is 7` |
| No service reachable, as the deploy invokes it | exit **1** — the skip becomes a failure |

For a manual run: `just eval-vision <url>`, or `just eval-vision <url> --record` to re-pin.
