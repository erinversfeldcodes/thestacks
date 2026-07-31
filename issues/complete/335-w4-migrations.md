# Issue #335: W4 child — Schema constraints: verification provenance, edition reference, FKs, checks

## Summary
Child of epic #314, Level 2. The migrations that move guarantees from application convention to the schema: where a book's ISBN verification came from (D1), the placement→edition reference that completes US-1.5.4 (D3 precondition), the two missing user FKs the deletion path compensates for in application code, and two CHECK/unique constraints.

## User Stories
US-1.1.2 (ISBN gate provenance), US-1.5.4 (format tracking / editions), US-14.x (auth token hygiene).

## Goal
Four invariants that are currently enforced by code-that-remembers become schema facts that hold regardless of which path writes the row — including paths that do not exist yet.

## Scope Check
Migrations + the changeset/schema updates they require. ⚠️ Keep behaviour changes out: if a migration forces a context rewrite beyond backfill wiring, that is a scope surprise — stop and report.

## Wiring
Router wiring: none. `verification_source` becomes visible to #315's provisional-title work; `book_edition_id` unblocks D3's per-edition ownership annotation.

## Feature-Completeness Pre-Check
n/a at this level — these are constraints under built features; #315 consumes them.

## Technical Requirements
1. **`book_editions.verification_source`** — NOT NULL, backfilled. Values per D1: `open_library` / `google_books` / `barcode_unverified`. The barcode fast path (`moderation.ex:484`) must write `barcode_unverified`, which is what makes "never externally verified" auditable instead of inferable from a `title LIKE 'ISBN %'` heuristic that vanishes when enrichment succeeds.
2. **`placements.book_edition_id`** — reference to `book_editions`, backfilled from each book's primary edition. **Keep `formats` during the migration** (retiring it is later work); this is the precondition for D3's per-edition owned/wishlist annotation.
3. **FKs the app currently compensates for**: `auth_token_families.user_id` → users, and an owner FK for `guardian_tokens.sub`. Then drop the corresponding hand-rolled cleanup in `gdpr/deletion.ex` **only if** the cascade genuinely covers it — state which you removed and why, and leave anything ambiguous in place with a note.
4. **Constraints**: `lower(email)` unique index + downcase-on-write; a CHECK constraint on the ISBN checksum. The checksum CHECK is the rung-4 version of a rule currently enforced in two places in application code — out-of-band writers (seeds, psql, a future importer) are exactly who it defends against.

## Reviewer Context
- BOOTSTRAP (worktree): `git merge --ff-only feat/campaign-w4-314` FIRST — it will contain #333 and #334. Copy `.env`; regenerate gen artifacts; `just run` for mix; `caffeinate -i` for long suites.
- ⚠️ **`mix test` deletes untracked generated migrations** — `git add` a generated migration IMMEDIATELY after creating it.
- ⚠️ **Concurrent indexes**: squawk requires `CREATE INDEX CONCURRENTLY`, which needs `@disable_ddl_transaction true` — and that is incompatible with a migration that also runs a guard or a `modify`. Wave 0 had to split one migration for exactly this (`20260730090000_rekey_price_snapshots_indexes.exs` is the pattern to copy: idempotent `*_if_not_exists`, new grain created before the old drops).
- **squawk runs in `just ci`, NOT `just verify`** — gate on `caffeinate -i just run just ci` before declaring green.
- `mix proto.sync` owns the generated columns: adding a column means editing the proto field and regenerating, not hand-writing an Ecto migration — check which of these four are proto-generated vs hand-written before you start, and follow the right path for each. `proto/persisted.exs` maps messages → tables.
- `gdpr-review` skill is REQUIRED on this diff (schemas + a user FK + a deletion-path change).
- Commit: agent commits are DENIED. Stage everything, write a ONE-LINE message (no body/trailers) to `/private/tmp/claude-501/-Users-erinversfeld-thestacks/78bc6659-34d4-45c2-b5b7-9a0337db2154/scratchpad/commit-msg-335.txt`. NEVER push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| DB interactions | yes | ❌ NOT NULL + backfill verified on a fresh DB; checksum CHECK rejects an invalid ISBN inserted out-of-band; `lower(email)` uniqueness rejects a case-variant duplicate; FK cascade proven by deleting a user and observing the child rows |
| Migration safety | yes | ❌ squawk green via `just run just ci`; fresh-DB `ecto.drop/create/migrate` clean |
| GDPR | yes | ❌ `gdpr-review` verdict cited; erasure still reaches everything it did before (the guard test must stay green) |
| Others | no | n/a |

## Definition of Done
- [ ] Four migrations applied cleanly on a fresh DB and on the preview branch — evidence: `ecto.migrate` output + preview deploy log
- [ ] Each constraint proven by a test that fails without it — evidence: test names (checksum CHECK, lower(email), FK cascade, NOT NULL backfill)
- [ ] squawk green — evidence: `just run just ci` squawk group output
- [ ] `gdpr-review` run and cited; deletion-path compensation removed only where the cascade provably covers it — evidence: verdict + diff rationale
- [ ] Suites green under `caffeinate` — evidence: counts
- [ ] `staff-review` verdict recorded below

## Dependencies
Epic #314. **Depends on #333** (same table — settle placement behaviour before constraining it) and benefits from #334 landing first (regenerated artifacts). Level 2.

## Agent Assignment
elixir-agent (migrations).

## Progress Notes
Filed 2026-07-30 (Wave 4 kickoff approved).
Built in worktree; commit 9e69e5ce; merged into `feat/campaign-w4-314`. 37 files, +1425/−108, nine migrations.
**staff-review verdict: LGTM** (2026-07-30, Mode B on 9e69e5ce). Praise: (a) it ran `proto.sync` **twice** for `verification_source` — first without `null: false` so the generated ADD COLUMN is safe on a populated table, then with it so the Ecto/dbt artefacts carry the constraint; that is the difference between a migration that works and one that works *on production data*; (b) the backfill is deliberately **conservative** — it can understate verification but never overstate it, which is the correct asymmetry for a provenance field feeding an audit; (c) the `guardian_tokens.sub` problem (a third-party `varchar` schema that cannot take a user FK) was solved with a `GENERATED ALWAYS AS (NULLIF(sub,'')::uuid) STORED` column carrying the FK — and it **verified against PG 16 that a stored generated column accepts an FK and cascades before writing the migration**, rather than discovering it in CI; (d) the ISBN CHECK is an inline EAN-13 expression, not a call to a helper function, on the stated grounds that "a CHECK calling a user function stops meaning what it said the day someone edits the function" — correct, and the kind of reasoning that does not show up in a diff; (e) downcase-on-write was placed **after** `validate_format` so whitespace is still rejected rather than silently trimmed into acceptance; (f) the email-normalisation migration **raises rather than guessing** if two rows already collide case-insensitively; (g) it kept the now-redundant `users_email_index` deliberately, because `unique_constraint(:email)` names it by default and dropping it would downgrade a friendly changeset error into a raised Postgrex error.
**The GDPR removal was not a deletion.** It removed both hand-rolled deletes in `:revoke_sessions` — justified, since both are now `ON DELETE CASCADE` FKs audited by the schema guard — but replaced them with a count-before / recount-after that **fails the whole transaction on any survivor**, so the operator break-glass summary keeps its number and a silently-broken cascade cannot be reported as success. It also extended `GDPR.Export` so `book_isbn` reports the edition the person actually shelved rather than whichever edition the work currently calls primary.
**Lead independent probe (the load-bearing claim — what justifies deleting GDPR code):** I probed the schema guard itself, on a freshly migrated DB. First confirmed both new FKs are genuinely `confdeltype = 'c'` in `pg_constraint`. Then weakened one to `ON DELETE NO ACTION` and re-ran: **4 failures**, with `Offenders: ["auth_token_families.user_id (a)"]`. Restored to CASCADE → **13 tests, 0 failures**. The guard is real and the compensations were safe to remove. Probe was DB-only; `git status` clean throughout.
**Mutation probes (child's, all red as claimed):** 7 DB-level constraint drops each reddening the test that claims them (`Expected exception Postgrex.Error but nothing was raised` ×5, `Ecto.ConstraintError` ×2), the GDPR cascade probe (`{:error, :revoke_sessions, {:sessions_survived_erasure, 1}, …}`), and 2 code-level. Backfill correctness was proven with an **anti-vacuous fixture** — a work whose *non-primary* edition was created first, so "picks the primary" cannot pass by accident.
**Fixture fallout absorbed:** the ISBN CHECK rejected ~14 hardcoded literals with wrong check digits across 5 test files (deliberately-invalid literals in checksum-rejection tests correctly left alone), plus 3 seed ISBNs. Two tests seeded two users differing only in case — now an unreachable state — and were rewritten to assert the property they were really protecting.
**gdpr-review: PASS.** Strict improvement: two user references erasure was compensating for in application code are now audited by the schema guard. `guardian_tokens.user_id` previously had **no FK at all**.
**Three findings filed rather than absorbed:** squawk vacuity → **#337**; `notes` free text in the warehouse → **#338** (routed into the owner's struck GDPR revisit, not scheduled now); `proto.sync` second-resolution timestamp collision (two migrations emitted as `20260730193134`, which Ecto rejects) → noted for Wave 11.
