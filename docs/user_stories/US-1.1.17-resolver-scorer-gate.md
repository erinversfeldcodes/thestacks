# US-1.1.17 — The Title Resolver Is Gated Like the Model

## 1. User Story

> **As a** reader whose cover photo carries no barcode, **I want** the title-to-ISBN resolution
> to be held to a recorded standard **so that** a "better" scorer that starts picking study
> guides over novels cannot ship quietly.

**Why this is a story.** Half of what the reader experiences as "recognition" happens AFTER the
model: catalogue search, scoring, the plausibility floor, the derivative penalty. A regression
here is invisible to the vision eval and lands directly on shelves.

**Acceptance criteria:**
- The scorer's pick logic is a single seam shared by production and its eval
  (`CandidateScorer.pick_best/3`), replayable offline from recorded signals and docs.
- `mix eval.resolver` gates changes: known-good picks stay picked, garbage stays floored,
  known-fails are named rather than hidden.
- Acceptance vocabulary is structural (floor, author corroboration, full title agreement) —
  never model confidence.

## 2. Current State (delivered, previously storyless)

- `mix eval.resolver` + `priv/eval/corpus.exs` run in `lint-elixir` on every verify (5 pass /
  0 fail / 2 known-fail as of 2026-11-20).
- The seam caught and pinned two live defects this cycle: the bag-of-words floor
  unreachability (title-agreement waiver, strict direction) and the subtitle-hidden
  derivative ("Luminous Emptiness" outranking the Tibetan Book of the Dead) — each with the
  live case as a verbatim test and a reverted mutation probe.

## 3. Validation

- `candidate_scorer_test.exs`, `isbn_resolver_test.exs`, and the eval replay — all in the
  default verify.
