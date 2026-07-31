# Issue #314: [EPIC] Campaign Wave 4 — Contracts and constraints

## Summary
Epic for Wave 4 of `plans/staff-campaign-2026-07-30.md`: schema and contract changes that ripple outward, landed before their consumers. Centrepiece is the owner-ruled **multi-shelf placement model** (2026-07-30): one ISBN may sit on multiple bookshelves; same-ISBN-same-shelf stays forbidden; the UI must surface multi-shelf presence.

## User Stories
US-1.1.6 (duplicate awareness), US-1.3.1/US-1.6.4 (book detail), US-1.5.1 (search annotation), US-1.1.2 (verification provenance), US-1.5.4 (edition reference).

## Goal
The placement model matches the ruling and cannot crash on it (live 500 fixed); verification provenance is a column; proto enums are closed types for Elixir with a lint gate; the event registry tells the truth; the named DB constraints exist.

## Scope Check
Epic; migration-bearing children follow migration standards (`docs/agents/standards/migrations.md`), one migration concern per child.

## Wiring
Router wiring: no new routes; book-detail + search UI changes are user-facing on completion.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-1.1.6 multi-shelf notice (photo path) | upload_controller.ex:419 is_duplicate → Upload.elm:279 | driven 2026-07-30 ✅ | ✅ | manual-path parity built in-scope here |
| US-1.1.6 manual path | none — no notice hop exists | driven: silent second placement | ❌ | build in-scope (informational notice, never block) |
| Book detail multi-shelf highlight | none — new per ruling | n/a — new | ❌ | build in-scope |

## Technical Requirements (child phases)
1. **Multi-shelf placement model**: keep the existing `(book_id, bookshelf_id) WHERE removed_at IS NULL` unique index (same-shelf dup ban — already rung 4). De-raise `get_placement_for_book/2` (`shelving.ex:673-679` `Repo.one()` → list; fix all 4 call sites incl. `book_controller.ex:276` — the live 500). Book detail: when a book sits on ≥2 of Library/Antilibrary/Reading Pile/Wish List, highlight it with per-placement remove affordances (Looking-for-a-Home excluded per ruling). Search "Your Collection" annotation lists all shelves. Manual-ISBN path gains the "Already in your collection on X" informational notice (parity with photo path; never blocks).
2. **verification_source**: `book_editions.verification_source` (`open_library` / `google_books` / `barcode_unverified`) NOT NULL backfilled (D1); barcode fast path writes `barcode_unverified`.
3. **Edition reference + FKs + checks**: `placements.book_edition_id` (backfill from primary edition; keep `formats` during migration — D3 precondition); FKs `auth_token_families.user_id`, owner for `guardian_tokens.sub`; `lower(email)` unique index + downcase-on-write; ISBN checksum CHECK constraint.
4. **Proto-enum codegen + registry truth**: generate an Elixir module per proto enum (`values/0`, `cast/1`); add consumer-coverage check to `scripts/lint-proto.sh` (each hand-written consumer's matched set ⊇ values minus documented ignores) — makes the #311-0d class a build failure; second drifted consumer `match_store_catalogue_job.ex:124` fixed as proof. Event registry: register or explicitly-ignore the 33 unregistered types; decide `image.*` observers; fix the "complete catalog" moduledoc.

## Reviewer Context
- **All five proto codegen targets** — run `bash scripts/lint-proto.sh`; an Ecto-only regen leaves wire structs adrift (hit twice before).
- `mix test` deletes untracked generated migrations — `git add` immediately.
- Squawk runs in `just ci`, not `just verify` — migration children gate on `just run just ci`.
- gdpr-review lens REQUIRED (migrations + schemas + event registry touched) despite the struck GDPR wave — the lens is per-diff and not struck.
- TestHelpers progress-field mismatch: #313 phase 3 chose a side; if the proto gains progress fields here instead, coordinate — exactly one of the two lands.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| DB interactions | yes | ❌ same-shelf dup rejected (constraint test); multi-shelf legal (place on 2 shelves via public API); de-raised lookup returns list |
| API + Elm | yes | ❌ book-detail highlight renders for 2-shelf book (program test + live drive); search annotation lists both; manual-path notice appears |
| Contracts | yes | ❌ enum codegen: removing a consumer clause fails `lint-proto.sh` (probe); registry completeness test |
| Others | no | n/a per layer at child spin-out (full audits per child) |

Punch: constraint tests ×2, lookup-list test, highlight program test + live drive, annotation test, notice test, lint-gate probe, registry test.
Verdict: baseline ❌ ×8.

## Definition of Done
- [x] Multi-shelf model live-driven on preview: same book placed on two shelves via UI, detail shows highlight + removes, search lists both, manual path shows notice, same-shelf second copy refused — evidence: driven 2026-07-31 on `stacks-core-pr-feat-campaign-w4-314`. Placed "Living to Tell the Tale" on library/wishlist/antilibrary (201/201/201); detail rendered **"This one is on 3 of your bookshelves"** with "Keep it that way if you meant to — or take it off the ones you didn't." and a per-row "Remove from here"; clicking Wish List's remove took **only** that placement (3 → 2, no navigation away); search rendered **"On your Antilibrary and Library shelves"** (plural, both named, reflecting the removal); manual-ISBN path rendered **"You already have this on your Library and Antilibrary."** with "Yes, that's it" still ENABLED (inform, never block); same-shelf duplicate refused **422 `book is already on this bookshelf`**. Screenshots ss_265084lka / ss_9396nzoui / ss_3091dsn4b / ss_0438f0jiu / ss_714422f42.
- [x] The 2026-07-30 500 repro (`GET /api/books/:id` owner-with-two-placements) now 200s — evidence: **200** carrying `placements: ["library","wishlist"]`, count 2. Control: the same endpoint on the Wave 3 preview still returns **500**.
- [x] Migrations applied cleanly on preview (Neon branch) + `just run just ci` green (squawk) — evidence: `PASS deploy: migrations applied`, `PASS deploy: migration integrity verified (105 repo migrations all applied)`; all three new constraints `convalidated = true` on `preview/feat-campaign-w4-314` (`book_editions_isbn_ean13_checksum`, `auth_token_families_user_id_fkey`, `guardian_tokens_user_id_fkey`). squawk PASS and **non-vacuous** — it selected all 9 new migrations once committed (see #337 for why it would otherwise have been vacuous). *Corrected by #337 (2026-07-31): the "8 of the 9 linted" originally written here was wrong twice over. Selecting a file is not analysing it — only **6** of the 9 yielded any squawk-analysable SQL, the other 3 being pure Ecto DSL. And one of those 3, `20260730200500_create_email_lower_and_placement_edition_indexes.exs`, was a migration whose entire job is building two indexes: it extracted zero statements because the DSL translator's regex matched `create index` but not `create_if_not_exists index`. That hole is now closed and the same nine files analyse 9 of 9.*
- [x] Enum-coverage lint probe: deleting a match clause fails the build — evidence: child probe reproduced the literal `f28c032e` defect (exit 0 → exit 1). **Lead probe went further**: a brand-new consumer file registered nowhere failed the gate — `FAIL: …/probe_new_consumer.ex matches on ScrapeOutcome but does not handle: SCRAPE_OUTCOME_RATE_LIMITED`, exit 1; removed → exit 0.
- [x] Feature-Completeness rows above all ✅ with live evidence — evidence: all four #333 rows driven live (see box 1); the two ❌ rows (500, no multi-shelf indication) and the 🟡 row (search naming one shelf) are each now demonstrated fixed on the preview.
- [x] Validation path per behaviour; suites green; `just verify` — evidence: elixir **3294/0**, elm **1344/0**, dialyzer 0 errors, credo clean, sobelow no vulnerabilities, dbt 243 PASS + checkpoint clean, proto all five targets.
- [x] Test audit GREEN; `completion-audit` passed; Completion Bar met (all cited) — evidence: every ❌ in the four child audits delivered; live drive performed (this is the box the wave was reopened for); preview logs during the drive contain **zero** `[error]` lines (the single grep hit was a `slow_query` warning whose text contains `decode=0ms`).
- [x] `gdpr-review` run on the diff — cite verdict — evidence: **PASS** on #335; strict improvement — two user references erasure was compensating for in application code are now CASCADE FKs audited by the schema guard, and `guardian_tokens.user_id` previously had **no FK at all**. Lead probed the guard itself: weakening one FK to `NO ACTION` reddened it with `Offenders: ["auth_token_families.user_id (a)"]`; restored → 13/13 green.
- [x] `staff-review` verdict per child in Progress Notes — evidence: #333 LGTM, #334 LGTM, #335 LGTM, #339 LGTM — each with an independent lead probe on a *different* target from the child's own.

## Dependencies
- #313 (test architecture) — honest fixtures must exist before constraint tests mean anything (a desynced-placement factory would fake the multi-shelf tests). Reason: sequencing rule 3.
- #312 — deletions land first so contracts aren't written for removed code. Reason: rule 1.
- Precedes #315 (its book-identity work consumes `verification_source` + the placement model) and #320's D3 story items.

## Agent Assignment
Orchestrator; children to elixir-agent (migrations/context), elm-agent (detail/search UI), proto/codegen specialist.

## Progress Notes
Filed 2026-07-30 by staff-campaign Stage 7. Owner rulings embedded: multi-shelf legal; same-shelf forbidden; highlight on the four named bookshelves.

## Progress Notes
Filed 2026-07-30 by staff-campaign Stage 7. Four children built in isolated worktrees across 3 dependency levels; merged 335fc400 (#334), 29e40692 (#333), 9e69e5ce (#335), 3f886211 (#339), plus two lead commits: 0d65582a (integration gaps the children could not see from their worktrees) and 149e1234 (release-command ordering).
**staff-review (epic cumulative): LGTM.** The wave delivered its contracts *and* found four defects nobody had specified.
**The wave was REOPENED after being green.** `just ci` passed and all three children were reviewed LGTM — then the live drive aborted the preview deployment on `book_editions_isbn_ean13_checksum`'s VALIDATE. #335 had verified on a fresh DB and on a DB it seeded itself; the preview inherits **real staging data** via Neon copy-on-write. **A constraint added to an existing table is a claim about existing data, and only real data tests it.** That produced #339, and measuring production directly showed 2 of 40 editions would have aborted the prod deploy identically.
**Then the repair itself was wired to a hook that never runs.** #339 ran its correction as a post-deploy `fly machine exec` in `scripts/deploy-stack.sh:1266`, but Fly's `release_command` executes `Stacks.Release.migrate()` *during* `fly deploy` and aborts before any post-deploy step — the repair sat behind the gate it was meant to open. Fixed by `Stacks.Release.deploy/0` (correct, then migrate) in `deploy/fly.core.toml` (149e1234). Third deploy green: `data-correction: normalise_edition_isbn10 (applied)` / `stale_seed_edition_isbn (applied)` → `PASS deploy: migrations applied`.
**Three gates in this one wave reported green while inspecting nothing** — squawk reading zero migrations (#337), coverage counting 401 lines of generated enum code as untested product code, and a repair behind its own failure. That is the campaign's central defect class, and it is why the live drive is not optional.
**Discoveries filed rather than absorbed:** #336 (Wave 2 deleted an event's sole emitter, leaving handler + contract + dbt mapping + two models), #337 (squawk vacuous for uncommitted migrations; sharpened by #339's finding that `SQUAWK_TARGET_DIR` scans all history — the fix must extend the *diff*, or the gate goes permanently red on 35 correct migrations), #338 (reader free-text `notes` in the warehouse against house convention — routed into the owner's struck GDPR revisit), #339, #340 (operationalise owner-facilitated data correction; consolidates two owner rulings, inherits #339's pattern).
**Owner rulings honoured and verified live:** multi-shelf legal (3 shelves, 201 each); same-ISBN-same-shelf still forbidden at rung 4 with the index **unwidened** (422); highlight on the four named bookshelves with per-placement remove; inform-never-block on both add paths; ISBN repair operationalised (dry-run, idempotent, audited) rather than a bespoke migration; seed process tightened so it cannot mint an unverified or unnormalised edition.
**Carried forward, not fixed:** `Stacks.Release.migrate/0` iterates every `:ecto_repos` entry, so a release task reusing that loop while calling `Core.Repo` explicitly crashes on the second iteration; `scripts/lint-migrations.sh` flags a pre-existing un-annotated `remove`; the `/search?q=` URL param is ignored by the search page (pre-existing, typing works).
**PR deferred by owner ruling** — wave PRs batch until the final wave; branch stays local, stacked on `feat/campaign-w3-313`.
