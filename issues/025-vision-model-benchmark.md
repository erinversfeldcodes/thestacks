# Issue #025: Vision Model Evaluation Framework

## Summary
Build a reusable, repeatable evaluation framework for vision model selection in The Stacks. The framework must be re-runnable whenever a new model appears, a prompt changes, or an architectural decision (e.g. adding a local OCR pre-pass) has implications for model choice. Results are committed to the repository so decisions are documented and reproducible.

This is not a one-off script. It is an experimental infrastructure investment.

## User Stories
US-1.1.1 — Upload a book photo and have it identified
US-1.1.2 — System rejects non-book images
US-1.1.3 — System handles ambiguous/low-confidence images gracefully

## Goal
Provide evidence-based model selection with a process that can be re-run at any time. The output of each run is a committed, versioned results artifact and a generated markdown report. Decisions are made from data, not intuition.

The first run establishes a quantitative baseline for the current model (`Qwen2.5-VL-7B-Instruct`) and surfaces whether a model upgrade is warranted before production launch. Subsequent runs compare against this baseline.

---

## Framework Design

### Directory Structure

```
apps/vision/benchmark/
├── corpus/
│   ├── annotations.csv          # ground truth — append-only, committed
│   ├── clean_barcode/           # category subdirs
│   ├── spine_only/
│   ├── oblique/
│   ├── worn_or_partial/
│   ├── multi_book/
│   ├── not_book/
│   └── ambiguous/
├── configs/
│   └── experiment-001.toml      # versioned experiment configs
├── prompts/
│   ├── classify-v1.txt          # versioned prompt files
│   └── extract-v1.txt
├── results/
│   └── YYYY-MM-DD-{run_id}.json # raw per-image results, committed
├── reports/
│   └── YYYY-MM-DD-{run_id}.md   # auto-generated, committed
├── run.py                       # benchmark entry point
├── metrics.py                   # scoring logic
└── compare.py                   # side-by-side comparison of two result files
```

### Corpus: Stratified, Not Random

Ground truth is locked in `corpus/annotations.csv` **before** any evaluation run. The CSV is append-only — existing rows are never modified. Rows are added as new images are sourced.

```csv
image_path,stratum,expected_classification,isbn_13,title,author,notes
clean_barcode/the-name-of-the-rose.jpg,clean_barcode,book,9780156001311,The Name of the Rose,Umberto Eco,clean retail shot
```

**Strata** (minimum counts for a valid run):

| Stratum | Min | Description |
|---------|-----|-------------|
| `clean_barcode` | 10 | Barcode clearly visible, ISBN machine-readable |
| `spine_only` | 10 | Spine/title text visible, no barcode |
| `oblique` | 5 | Angled, in poor light, or low-res phone photo |
| `worn_or_partial` | 5 | Sticker over barcode, worn edge, partial cover |
| `mirrored_cover` | 5 | Front cover photographed in selfie/mirror mode — text horizontally flipped. Tests whether pre-flip pre-processing is needed or whether the model handles it reliably. |
| `multi_book_image` | 5 | Single image containing multiple visible books (e.g. a shelfie, a stack). Model should extract all identifiable books, not just one. |
| `screenshot_text` | 10 | Screenshot of text referencing books — social media post, article, TikTok caption, reading list. No physical book visible. Model must classify as book-related and extract title/author from text. |
| `not_book` | 10 | Random objects, documents, people — must reject |
| `ambiguous` | 5 | Model is expected to return `ambiguous` |

**Total minimum**: 65 images. All images must be real photographs or real screenshots — no synthetic inputs.

**Notes on new strata:**
- `mirrored_cover`: ground truth ISBNs/titles are the same as the non-mirrored book. This stratum isolates whether the model needs pre-processing help or handles flipped text natively.
- `multi_book_image`: ground truth is a list of ISBNs (all visible books). ISBN recall is computed across all ground-truth books in the image, not just the first one the model returns.
- `screenshot_text`: these images contain no barcode and often no full title on a single line. ISBN recall will be low by design — the primary metric here is title/author extraction accuracy and correct classification as book-related (not rejection as `not_book`).

### Experiment Config (TOML)

Each run references a named experiment config:

```toml
# apps/vision/benchmark/configs/experiment-001.toml
[experiment]
id = "001"
description = "Baseline — Qwen2.5-VL-7B vs 72B, classify-v1 prompts"
date = "2026-03-10"

[[models]]
name = "Qwen/Qwen2.5-VL-7B-Instruct"
label = "7B-baseline"

[[models]]
name = "Qwen/Qwen2.5-VL-72B-Instruct"
label = "72B-candidate"

[[models]]
name = "meta-llama/Llama-3.2-11B-Vision-Instruct"
label = "llama-11B-candidate"

[prompts]
classify = "classify-v1.txt"
extract = "extract-v1.txt"

[thresholds]
# Per-stratum pass thresholds. A run that misses any threshold is flagged in the report.
classification_f1_book = 0.90
classification_f1_not_book = 0.95
isbn_recall_clean_barcode = 0.85
isbn_recall_spine_only = 0.50
title_similarity_spine_only = 0.70
# mirrored_cover: same thresholds as clean_barcode — if pre-flip is applied upstream,
# the model sees a normal image. A significant gap vs. clean_barcode indicates the
# pre-flip is doing real work (or that the model degrades on flipped text).
isbn_recall_mirrored_cover = 0.80
# multi_book_image: recall across all ground-truth books in the image (not just first)
isbn_recall_multi_book_image = 0.50  # intentionally lenient — partial extraction is valuable
# screenshot_text: no barcodes present, so ISBN recall is not the primary metric.
# title_similarity is the key signal here.
title_similarity_screenshot_text = 0.65
# screenshots must be classified as book-related, not rejected as not_book
false_positive_rejection_screenshot_text = 0.10  # ≤10% of screenshots may be wrongly rejected
false_positive_rate_not_book = 0.05
latency_p95_ms = 5000
```

### Metrics

Metrics are computed **per stratum** and per model, not as overall aggregates. Per-stratum breakdown is mandatory — headline accuracy hides stratum failures.

**Classification metrics** (per stratum, per model):
- Precision, recall, F1 for each class (`book`, `not_book`, `ambiguous`)
- Confusion matrix

**Extraction metrics** (strata with ground-truth ISBNs/titles):
- ISBN recall: fraction of ground-truth ISBNs correctly extracted
- ISBN false positive rate: fraction of extracted ISBNs that don't match ground truth
- Title similarity: fuzzy string match (SequenceMatcher ratio ≥ 0.8 = pass) against ground truth
- Author similarity: same

**Latency** (wall-clock, per model):
- p50, p95, p99 across all images in run
- Measured at the `VisionClient` level (not HTTP round-trip)

**Cost** (per model):
- Input + output tokens per image (from Together AI response headers)
- Estimated cost per 1,000 production uploads at current pricing
- Note: pricing recorded at run time in config; re-running later may reflect new pricing

### Versioned Prompts

Prompts live in `benchmark/prompts/`. Each version is a separate file (`classify-v1.txt`, `classify-v2.txt`). The experiment config pins the prompt version used. This means a benchmark re-run with a new prompt produces a separate, comparable result rather than silently changing what was measured.

Prompt files contain the raw system/user prompt text sent to the model. The benchmark harness reads these files at runtime — no hardcoded strings in `run.py`.

### Run Script

```
# Single model run
python apps/vision/benchmark/run.py --config configs/experiment-001.toml --model 7B-baseline

# All models in config
python apps/vision/benchmark/run.py --config configs/experiment-001.toml --all-models

# justfile alias
just benchmark [args]
```

Outputs:
- `results/YYYY-MM-DD-{run_id}-{model_label}.json` — raw per-image results
- `reports/YYYY-MM-DD-{run_id}-{model_label}.md` — auto-generated markdown report

Both files are committed to the repository. This is intentional: decisions are auditable and the corpus + results together form a regression test corpus for future changes.

### Compare Mode

```
python apps/vision/benchmark/compare.py results/A.json results/B.json

# justfile alias
just benchmark-compare results/A.json results/B.json
```

Prints a side-by-side table: per-stratum delta for each metric, with wins/losses highlighted.

### Auto-Generated Report Structure

Each report includes:
1. Run metadata (date, config, model, corpus size per stratum)
2. Per-stratum classification F1 table
3. Per-stratum extraction accuracy table
4. Latency summary (p50/p95/p99)
5. Cost summary (per image, per 1,000 uploads)
6. Threshold pass/fail table (red/green per threshold from config)
7. **Go/no-go recommendation**: auto-derived from threshold table — PASS if all thresholds met, FAIL with list of failing thresholds otherwise
8. Human decision notes section (free-text, filled in after reviewing the report)

---

## Key Design Principles

1. **Ground truth is locked before evaluation.** `annotations.csv` is committed before any model is run. No cherry-picking.
2. **Strata, not overall accuracy.** A model that aces clean barcodes but fails oblique shots is not acceptable. Per-stratum metrics are mandatory.
3. **Cost is a metric.** Accuracy and latency without cost data is incomplete. Token counts and estimated pricing are first-class outputs.
4. **Prompts are versioned.** Changing a prompt without bumping the version is not allowed. Results are only comparable when prompts are identical.
5. **Results are committed.** `results/` and `reports/` are not `.gitignore`d. Future developers can see the evidence behind model decisions.
6. **Re-runnable by design.** The framework handles any Together AI model. Adding a new model requires only a new `[[models]]` block in the config. No code changes.

---

## Justfile Recipes

Add to the root `justfile`:

```just
# Run vision model benchmark (see apps/vision/benchmark/README.md)
benchmark *ARGS:
    cd apps/vision && PYTHONPATH=. .venv/bin/python benchmark/run.py {{ARGS}}

# Compare two benchmark result files side-by-side
benchmark-compare result_a result_b:
    cd apps/vision && PYTHONPATH=. .venv/bin/python benchmark/compare.py {{result_a}} {{result_b}}
```

---

## Definition of Done

- [ ] `benchmark/` directory structure created with all listed files
- [ ] `corpus/annotations.csv` schema defined and at least 50 images annotated
- [ ] `benchmark/run.py` implemented (reads config, runs VisionClient, writes results JSON)
- [ ] `benchmark/metrics.py` implemented (per-stratum F1, ISBN recall, title similarity, latency, cost)
- [ ] `benchmark/compare.py` implemented (side-by-side delta table)
- [ ] Report generator implemented (reads results JSON, writes markdown report)
- [ ] At least one experiment config committed (`configs/experiment-001.toml`)
- [ ] Prompts versioned in `prompts/` (not hardcoded)
- [ ] First run executed against all three candidate models
- [ ] Results JSON committed to `results/`
- [ ] Report committed to `reports/`
- [ ] Model selection decision recorded in `apps/vision/app/config.py` comment with rationale
- [ ] `just benchmark` and `just benchmark-compare` recipes added to justfile
- [ ] If a model change is recommended, update `model_name` default in `config.py`

---

## Sequencing

**Starts after**: Phase 1D (vision sidecar) committed and Together AI API key provisioned.

**Does not block**: Phase 1D.2 (local OCR pre-pass). Phase 1D.2 is model-agnostic and additive. The model can be changed at any time via `VISION_MODEL_NAME` env var. Phase 1D.2 should be evaluated using the benchmark framework once implemented — it is a candidate experiment, not a prerequisite.

**Should complete before**: Production launch at meaningful scale. The ISBN hard gate means silent misidentification is the primary risk. A benchmark failure may warrant a model upgrade before opening to users beyond the owner.

---

## Dependencies
- Issue #003 merged (vision sidecar implemented)
- Together AI API key with access to all three candidate models
- Real book photo corpus (human task — sourced before first run)

## Agent Assignment
python-agent for harness, metrics, compare, and report generator implementation. Corpus assembly, ground truth annotation, and final model decision are human tasks.

## Progress Notes
Originally scoped as a one-off benchmark script. Redesigned as a reusable evaluation framework based on industry model evaluation best practices: stratified corpus, locked ground truth, versioned prompts, per-stratum metrics, cost as a first-class metric, committed results.
