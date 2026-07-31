# Issue #339: The ISBN checksum VALIDATE aborts the deploy — and finds real hard-gate violations

## Summary
Found by the lead's Wave 4 live drive on 2026-07-30. #335's `20260730200350_validate_new_constraints` **aborted the preview deployment**:

```
** (Postgrex.Error) ERROR 23514 (check_violation) check constraint
   "book_editions_isbn_ean13_checksum" of relation "book_editions"
   is violated by some row
✖ Failed: machine 7845039f949378 exited with non-zero status of 1
Error: release command failed - aborting deployment.
```

The constraint expression is **correct** — verified against a known-good ISBN (`9780141036144` → `true`). The data is wrong, and it is wrong in two different ways:

| Environment | Rows | Nature | Repairable? |
|---|---|---|---|
| **production** (`square-art-39019825`) | **2 of 40** | Valid **ISBN-10**s stored in the ISBN-13 column (`0071615695`, `0062028510`) — ISBN-10 check digits verified valid (165 and 121, both ÷11) | **Yes, deterministically** — prefix `978`, recompute check digit |
| **staging** (`royal-boat-46711655`) | 3 | 13-digit values with wrong EAN-13 check digits (`9780446611972`, `9780156030358`, `9780679775474`), `created_at` = `2026-01-01`, both `open_library_id` and `google_books_id` NULL — fabricated seed/demo data | **No** — no correct value to derive |

Both production rows have **0 active placements**, so no reader's shelf depends on them.

## Why this matters beyond the migration
Every one of these rows has **NULL `open_library_id` AND NULL `google_books_id`** — they were never verified against an external catalogue. CLAUDE.md's ISBN hard gate ("No book enters the system without a verified ISBN … non-negotiable") has a hole somewhere, and this constraint is the first thing that has ever measured it. `Books.to_isbn13/1` exists and is used in `find_existing/1`, so at least one write path reaches `book_editions` without normalising to ISBN-13.

## User Stories
US-1.1.2 (ISBN gate). No new UI.

## Goal
The migration deploys cleanly to production, and the ISBN gate's guarantee is true of every row rather than only of rows written through the happy path.

## Scope Check
One repair migration + the VALIDATE sequencing + a write-path trace. Single concern.

## Wiring
Router wiring: none. Migration + data repair.

## Technical Requirements

⛔ **Owner ruling 2026-07-30 shapes this issue: repair-then-validate, done as a REUSABLE capability, not a bespoke migration.** Verbatim: *"we should do this in a way that informs how we handle the repair of bad data in the future, ideally operationalising this kind of repair."* This is the same theme as the earlier campaign ruling on un-merge (*"a form of data correction that we should be building processes for"*), so build the pattern here and let un-merge inherit it (see #340).

1. **Build the repair as a named, re-runnable operation — not an inline `UPDATE` in a migration.** Minimum shape:
   - **dry-run by default**, reporting exactly which rows it would change and to what, so the operator sees the blast radius before anything moves;
   - **idempotent** — running it twice changes nothing the second time;
   - **audited** — each correction leaves a record of what was changed, from what, to what, and why (the `audit` schema exists for this);
   - **scoped by an explicit predicate**, never "fix everything that looks wrong".
   The ISBN repair is its first caller. Keep it small — a mix task plus a context function is enough; this is a pattern to inherit, not a framework.
2. **Repair what is deterministically repairable** — the two production ISBN-10s convert losslessly (prefix `978`, drop the ISBN-10 check digit, recompute the EAN-13 check digit). Assert the converted values pass the CHECK *before* validating. Unit-test the conversion against both real production values.
3. **Handle the unrepairable rows explicitly.** The three staging rows have no derivable correct value. Do not silently delete them — decide and document, and let the mechanism in (1) record the decision.
4. **Then `VALIDATE`**, so the constraint becomes a true statement about every row rather than only about future writes.
5. **Trace the write path that produced them** (rung 1 → rung 4). ⛔ **Owner ruling: *"bear in mind this may be as a result of bad seed data. If it is then we need to correct the seed data and also tighten the seed process to not allow this."*** So the trace has two possible endings, and both carry work:
   - **If seeds are the source**: fix the seed values **and** make the seed path incapable of producing them — a seed that can mint an unverified, unnormalised edition is the same defect class as a factory that can build an impossible state (which #329 closed for factories; do the equivalent here).
   - **If a production write path is the source**: that is the ISBN hard gate leaking, and it is the more serious finding — fix it or file it with evidence.
   A `verification_source = 'barcode_unverified'` row is legitimate; a row with *no* identifiers **and** an unnormalised ISBN is not.
6. **Re-drive the preview deploy to green** — this issue is not done until `scripts/deploy-preview.sh` completes and the Wave 4 live drive can run.

## Reviewer Context
- ⚠️ The **fresh-DB and seeded-DB tests both passed** — #335 verified on a fresh migration run and on a DB it seeded itself. Only the preview, which inherits **real staging data via Neon copy-on-write**, caught this. That is the lesson: a constraint added to an existing table is a claim about *existing data*, and only real data tests it.
- The `NOT VALID` → `VALIDATE` split #335 used is the **correct** pattern and should be kept; the failure is in the data, not the pattern.
- ISBN-10 → ISBN-13 conversion is deterministic; do not use a lookup or an external API call for it.
- Do **not** modify production data outside a reviewed migration.
- `gdpr-review` not required (catalogue data, not personal).
- Commit: agent commits are DENIED. Stage, one-line message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Migration safety | yes | ❌ repair migration idempotent; VALIDATE succeeds after it; probe by re-running |
| DB interactions | yes | ❌ ISBN-10 → ISBN-13 conversion unit-tested against both production values |
| Deploy | yes | ❌ preview deploy completes green — the actual acceptance test |
| Wiring | yes | ❌ the write path that skips normalisation is identified and either fixed or filed |
| Others | no | n/a |

## Definition of Done
- [x] Grandfathering decision recorded with rationale — evidence: owner ruling quoted; repair-then-validate built as `Stacks.DataCorrection`
- [x] Deterministic repairs applied and asserted — evidence: `0071615695 → 9780071615693`, `0062028510 → 9780062028518`, both unit-tested and driven against a local DB carrying the real constraint
- [x] Unrepairable rows handled explicitly — evidence: `Stacks.DataCorrection.StaleSeedEditionIsbn` moduledoc records the decision and why deletion was rejected
- [x] Write path traced — evidence: two different sources, both closed (see Progress Notes)
- [x] **Preview deploy green and Wave 4 live drive completed** — evidence: deploy green 2026-07-31 (`data-correction: normalise_edition_isbn10 (applied)` / `stale_seed_edition_isbn (applied)` → `PASS deploy: migrations applied` → `105 repo migrations all applied`); all three constraints `convalidated = true` on `preview/feat-campaign-w4-314`; the three previously-bad staging ISBNs now read 9780156030359 / 9780446611978 / 9780679775478. Full Wave 4 drive completed on that preview (see #314). ⚠️ Required one further fix by the lead: the correction was wired as a post-deploy `fly machine exec`, but Fly's `release_command` runs the migrator during `fly deploy` and aborts first — added `Stacks.Release.deploy/0` (correct, then migrate) in `deploy/fly.core.toml`, commit 149e1234.
- [x] `staff-review` verdict recorded below — evidence: LGTM, Progress Notes

## Dependencies
**Blocks the completion of epic #314 (Wave 4)** — the live drive cannot run until the preview deploys. Depends on #335 (introduced the constraint).

## Agent Assignment
elixir-agent (migrations + write-path trace).

## Progress Notes
Filed 2026-07-30 by the lead during the Wave 4 live drive. Deploy log: `scratchpad/w4-preview.log`. Constraint expression independently verified correct before blaming the data. Production impact measured directly (2 of 40 editions, 0 active placements). **Awaiting owner ruling on grandfathering vs repair-then-validate before execution.**

**Owner rulings 2026-07-30 (binding):**
1. On the repair approach — *"we should do this in a way that informs how we handle the repair of bad data in the future, ideally operationalising this kind of repair."* → repair-then-validate, built as the reusable mechanism in Technical Requirement 1. The three options offered (repair/grandfather/split) were all declined in favour of this.
2. On the hard-gate hole — *"1, but bear in mind this may be as a result of bad seed data. if it is then we need to correct the seed data and also tighten the seed process to not allow this."* → trace it now, inside this issue; if seeds are the source, fix the values AND make the seed path unable to reproduce them.
Related: **#340** carries the fuller owner-facing data-correction process (un-merge and future corrections) that inherits the pattern built here.

---

### Implementation 2026-07-30

**Write-path trace — two sources, not one.** Both endings the owner anticipated turned out to be present, in different environments.

*Staging (3 rows) — seeds.* The ids are `a1b2c3d4-0000-0000-0000-0000000040{76,96,117}`, i.e. `Seeds.uuid(3000 + edition_index)` (`apps/core/priv/repo/seeds.exs:14`), and `created_at` is the seed's `jan_01` constant. `git log --all -S` places all three literals in `seeds.exs` from `2b265fa9` ("restructure seeds for works/editions model") until **#335's own commit `9e69e5ce` corrected them in place** — so the seed *values* were already fixed before this issue was filed; the rows in staging simply predate that fix and `on_conflict: :nothing` (keyed on the fixture UUID) can never overwrite them.

*Production (2 rows) — the application write path, historically.* Created `2026-04-21T17:02:38Z` and `2026-04-22T07:02:20Z`. `Books.book_edition_changeset/2` gained `normalize_edition_isbn/1` on **2026-05-15** (`170c8639`); before that it accepted a valid ISBN-10 (`validate_format ~r/^\d{10}(\d{3})?$/` + `validate_isbn_checksum`) and stored it verbatim (`git show 170c8639^:apps/core/lib/stacks/books.ex`, lines 990-997). Both rows were written through the normal path, three weeks before it learned to normalise. The leak is closed in code and now closed in the schema too; `apps/core/test/stacks/books_test.exs:107` already covers the normalisation.

**Seed process tightened (owner ruling 2).** The seed writes editions with `Repo.insert_all/3` for deterministic ids and fixed timestamps, and bought a bypass of every validation with it — #335 noticed and hand-set `verification_source` rather than routing through the changeset. Every seeded edition row now goes through `Stacks.Books.vet_edition_row!/1`, which runs the **production** `book_edition_changeset/2` and raises before `insert_all/3` sees the row. It also normalises, so the seed cannot mint an unnormalised ISBN-10 either. `apps/core/test/stacks/seed_honesty_test.exs` is the #329 sibling: it asserts every ISBN literal in `seeds.exs` is a checksum-valid ISBN-13, that the file still routes through the gate, and that the gate rejects each of the three literals that actually reached staging.

**Grandfathering decision — the three staging rows are corrected, not deleted.** They are their work's only edition and carry live placements (1, 2 and 1); deleting them would empty a seeded reader's shelf and drop three works. Their correct value is not a guess: for a fixture row `seeds.exs` is the source of truth, and it now declares one. `Stacks.DataCorrection.StaleSeedEditionIsbn` pins all three `(id, from, to)` triples so it can only ever touch a row still holding the exact pre-#335 literal, and `seed_honesty_test.exs` asserts the table cannot drift from the file. The correction is one-way; the old value survives in the audit row.

**Deploy.** `scripts/deploy-stack.sh` runs the corrections immediately before migrating, on both the runner-side prod path (`mix stacks.data.correct --apply`) and the in-container path preview uses (`Stacks.Release.correct_data(apply: true)`). A constraint added to an existing table is a claim about existing data, so the repair has to land ahead of the migration that validates it.

**Not built here:** no migration was added. `docs/agents/standards/migrations.md` forbids migrations importing app modules and the owner forbade an inline `UPDATE`; running the named operation before `Ecto.Migrator` satisfies both.

**staff-review verdict: LGTM** (2026-07-30, Mode B on 3f886211, merged as ac03241a). Praise: (a) the write-path trace reached **both** endings the owner anticipated and proved each with history rather than inference — staging's three are seed rows (`Seeds.uuid(3000 + i)` ids, `jan_01` timestamps) whose literals #335's own commit had already corrected, and production's two were written by the ordinary path **three weeks before it learned to normalise** (`normalize_edition_isbn/1` added 2026-05-15 in `170c8639`; rows created 2026-04-21/22, confirmed by read-only Neon query). That converts an alarming "the ISBN hard gate is leaking" into a dated, closed regression — a materially different and better-evidenced conclusion than the issue assumed; (b) the seed tightening routes every seed edition through the **production changeset** (`vet_edition_row!/1`) and returns its *normalised* ISBN, so the seed cannot mint an unnormalised ISBN-10 either — the #329 factory treatment applied to seeds, with `seed_honesty_test.exs` as its sibling guard; (c) the audit write happens **inside the correction's transaction**, so a correction that cannot be recorded is rolled back — and it proved `ensure_vault!/0` matters by running under `--no-start`, where `Stacks.Audit` rescues its own failures and the trail would otherwise have been silently empty in exactly the context it exists for; (d) it declined to add a migration, reasoning from `docs/agents/standards/migrations.md` (migrations must not import app modules, since "a migration is frozen at its commit; the module it imports is not") against the owner's ban on an inline UPDATE, and resolved the conflict by running the named operation *before* `Ecto.Migrator` on both deploy paths; (e) the acceptance test reads the constraint out of `pg_get_constraintdef` rather than re-spelling it, so it validates against the production expression verbatim; (f) it checked before proposing deletion — all three staging rows are their work's only edition and carry live placements (1, 2, 1), so deleting would have emptied a reader's shelf.
**Lead independent probe (different target from the child's):** the child probed the seed gate. I probed the *reassuring* claim instead — that the production leak is already closed — by removing `normalize_edition_isbn()` from the edition changeset pipeline. **3 failures across both files**: `create/1 accepts isbn-10 with valid checksum and normalises to isbn-13`, plus two `vet_edition_row!/1` tests including `what it returns is what the database accepts`. The closed-gate claim is load-bearing, not assumed. Restored via **Edit**; `git status` clean, `grep -c` → 1.
**Owner rulings honoured:** repair built as `Stacks.DataCorrection` (behaviour + runner, dry-run by default, idempotent by construction, audited, explicitly scoped) with `mix stacks.data.correct` and `Stacks.Release.correct_data/1` entry points — not a bespoke migration; and the seed process is now structurally unable to reproduce the defect. Dry-run/apply/re-apply transcript verified: dry run leaves all 5 rows unchanged with 0 audit rows; apply fixes 5 and writes 5 audit rows; second apply reports `rows: 0`, still exactly 5 audit rows; `VALIDATE CONSTRAINT` then succeeds with `convalidated = t`.
Suites: elixir **3294/0** (32 new), dialyzer **0 errors**, credo clean, sobelow **no vulnerabilities**.
**Findings carried forward:** (1) `SQUAWK_TARGET_DIR` scans whole history, not a diff — reports 35 pre-existing `require-concurrent-index-creation` violations on 2026-03-05 table-creation migrations; **#337 must scan the diff or the gate will be permanently red** (added to #337). (2) `Stacks.Release.migrate/0` iterates every `:ecto_repos` entry, so a release task reusing that loop while calling `Core.Repo` explicitly crashes on the second iteration — worth fixing before the next release task is written. (3) `scripts/lint-migrations.sh` flags a pre-existing un-annotated `remove` in `20260318065431_create_book_editions.exs`.
