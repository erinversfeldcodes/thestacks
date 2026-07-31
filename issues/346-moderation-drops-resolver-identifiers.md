# Issue #346: The upload path drops the resolver identifiers it just paid for

## Summary
Found by #341 while collapsing the two create transactions, and confirmed by the lead. `Moderation.build_book_attrs/4` (`apps/core/lib/stacks/moderation.ex:495-527`) resolves an ISBN and then hands `Books.create/1` an attrs map with **neither `open_library_id` nor `google_books_id`**. Every edition minted from an upload is therefore missing the cross-reference identifiers the resolver returned.

This is precisely the defect #341 just fixed — one caller upstream. #341 collapsed `create/1` and `create_confirmed_book/4` because the latter dropped `google_books_id`; the vision/upload path drops **both**, before the create is even called, so the unified transaction never sees them.

## Why it has gone unnoticed
The upload path sets `verification_source` **explicitly** (`barcode_unverified` on the barcode fast path), so it never falls through to `Books.verification_source_from/1` — which is the function that would otherwise have noticed there are no identifiers to read provenance from. The explicit set is correct on its own terms; it just means the missing identifiers produce no visible symptom.

## User Stories
US-1.1.2 (ISBN gate provenance), US-1.1.3 (photo → book).

## Goal
An edition created from an upload carries the same identifiers as one created from manual entry or confirm. Provenance does not depend on which door the book came through.

## Scope Check
One function in one context module, plus its tests. Well under the bar.

## Wiring
Router wiring: none. Internal — the identifiers become visible via `ProtoJSON.edition/1`, which already serialises them.

## Feature-Completeness Pre-Check
n/a — no new story surface. The pre-check that matters is a **zero/null sweep**: count upload-created editions with NULL `open_library_id` AND NULL `google_books_id` before the fix, as the evidence the defect is real and its size.

## Technical Requirements
1. **Pass the resolver's identifiers through** `build_book_attrs/4` into the create. The unified `create_work/2` (from #341) already accepts and persists them — this is a plumbing fix, not a schema change.
2. **Do not disturb the explicit `verification_source`** on the barcode fast path. `barcode_unverified` is deliberate and correct: a barcode scan that has not been confirmed against an external catalogue must not claim to have been. Passing identifiers through and stating provenance explicitly are independent, and both should hold.
3. **Null-sweep the existing rows** and decide whether a backfill is warranted. If it is, use the `Stacks.DataCorrection` mechanism built in #339 (dry-run by default, idempotent, audited) rather than an ad-hoc migration — that is the pattern the owner asked for, and this is exactly its second consumer.
4. **Guard it.** The reason this survived is that nothing asserted the identifiers on the upload path. Add the assertion that would have caught it.

## Reviewer Context
- BOOTSTRAP (worktree): `git merge --ff-only <the wave branch this is scheduled into>` FIRST — local, unpushed; no `git fetch`, no `origin/`. Copy `.env`; regenerate proto artifacts; `just run` for mix; `caffeinate -i` for long suites.
- **NEVER revert a probe with `git checkout`** — use Edit, verify with `grep -c`.
- ⚠️ #341 collapsed the create paths — there is now exactly **one** `Multi.insert(:book, …)` in `books.ex`. Route through it; do not add a second path for the upload case.
- `Books.verification_source_from/1` derives provenance from the identifiers. Once they are passed through, check whether the explicit set on the *non-barcode* upload paths is still the right call or whether derivation is now more truthful — state the decision either way.
- Related prior art: #341 (the same defect downstream), #339 (`Stacks.DataCorrection` for any backfill).
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| DB interactions | yes | ❌ an upload-created edition carries the resolver's identifiers — mutation-probe by dropping one |
| Oban jobs | yes | ❌ the vision/identify path end-to-end preserves them |
| Warehouse | yes | ❌ null-sweep count captured before/after |
| Others | no | n/a |

## Definition of Done
- [x] Identifiers passed through to the unified create — evidence: `Moderation.build_book_attrs/4` now sets `"open_library_id"`/`"google_books_id"`; tests `run_pipeline/1 — the resolver's cross-reference ids reach the row (#346)` (3 tests, `moderation_test.exs`)
- [x] `verification_source` behaviour on the barcode fast path unchanged — evidence: `the barcode fast path still records that nothing external confirmed it` (new) plus the two pre-existing `local-OCR fast path` tests, all green
- [x] Null sweep captured; backfill decision stated — evidence: prod 40/40 editions carry neither identifier while 38/40 carry a resolver-supplied `publication_year`; backfill warranted, vehicle is re-enqueuing `EnrichBookJob`, NOT `Stacks.DataCorrection` (its `plan/0` runs inside `fly deploy` via `Release.deploy/0`, and the value needs a third-party lookup rather than arithmetic on the row)
- [x] Mutation probe on the new assertion — evidence: 3 probes, each red on exactly its own assertion (see Progress Notes)
- [x] Suites green — evidence: 15 properties, 3343 tests, 0 failures, 9 excluded; `mix format --check-formatted` clean; `mix credo --strict` 4114 mods/funs, no issues
- [ ] `staff-review` verdict recorded below

## Dependencies
**#341** (built the unified create this routes into; found the defect). Optionally **#339** (`Stacks.DataCorrection`) if a backfill is taken. Not yet scheduled into a wave — needs an owner assignment.

## Agent Assignment
elixir-agent.

## Progress Notes
Filed 2026-07-31 by the lead from #341's finding 1, during Wave 5.

**2026-07-31 — built (elixir-agent).**

*Null sweep (production, `square-art-39019825`).* 40 editions, **40 with neither
`open_library_id` nor `google_books_id`** — 0 with either. All 40 came from the
upload path: 40 `book.created` events, 0 `books.confirmed`, 0
`books.edition_merged`, against 7 123 `image.submitted` / 2 911 `image.resolved`.
All 40 have a real (non-`"ISBN …"`) title and 38 have a resolver-supplied
`publication_year`, 17 a `publisher`, 17 a `cover_image_url` — every one of those
fields travels in the SAME metadata map as the two identifiers, so the payload
demonstrably reached the row and exactly the two id keys were dropped. Staging
and local hold 200 rows each, all from `seeds.exs`; not evidence either way.

*Fix.* Two functions, four lines: `Moderation.build_book_attrs/4` (the sync
resolve) and `EnrichBookJob.update_primary_edition/2` (the async half — the
barcode fast path resolves no metadata, so the create has no id to carry and
this job is the round-trip for those rows; without it the fix would not have
reached the dominant upload path at all). Both route through the single
`Multi.insert(:book, …)`/`edition_attrs/2` contract from #341 — no new path.

*`verification_source` decision.* The explicit `"barcode_unverified"` stays on
the barcode fast path, unchanged. On every OTHER upload path the explicit set is
**removed** and the value is now derived by `Books.edition_attrs/2`. It called
`Books.verification_source_from/1` on the resolver metadata, which is the same
answer — but computed from a different map than the one being written, and two
maps allowed to disagree is precisely how this bug hid: the provenance claim
looked right while the columns it describes sat NULL. Derived downstream, the
claim and its evidence are always the same row. The fast path keeps stating it
because `used_fast_path` ("we deliberately skipped the lookup") is the one fact
about that row no column records.

*Backfill decision — warranted, but not as a `Stacks.DataCorrection`.* Warranted
because migration `20260730200000` (this release, undeployed) stamps
`verification_source` from these columns and then freezes it NOT NULL + CHECK:
with both NULL it writes `barcode_unverified` for all 40, and since #344 the SPA
renders a provisional book distinguishably off exactly that value — 40 fully
identified books would show as unidentified. Not a `DataCorrection` because the
value is not derivable from the row (`NormaliseEditionIsbn10` states the rule:
"the conversion is arithmetic, not a lookup"), and `Stacks.Release.deploy/0`
runs `correct_data(apply: true)` as Fly's `release_command`
(`deploy/fly.core.toml:12`) with `run_corrections/1` raising on failure — so 40
Open Library round-trips in `plan/0` would put a third-party outage in the path
of every deployment, inverting #339's reason for existing, and would never empty
for a permanently unresolvable ISBN. The vehicle is the path this fix repaired:
`EnrichBookJob` resolves the ISBN and now writes both ids and the derived
provenance. **After this release deploys**, re-enqueue it for the affected rows:

```
/app/bin/core rpc 'import Ecto.Query; alias Stacks.Books.BookEdition; Core.Repo.all(from e in BookEdition, where: is_nil(e.open_library_id) and is_nil(e.google_books_id), select: e.isbn) |> Enum.each(&Oban.insert!(Stacks.Workers.EnrichBookJob.new(%{"isbn" => &1})))'
```

Order is safe: the migration's `barcode_unverified` stamp is a legal CHECK value
and `update_primary_edition/2` overwrites it once the resolver answers.

*Mutation probes* (each reverted with Edit, never `git checkout`; restoration
confirmed with `grep -c`):

| probe | result |
|-------|--------|
| drop `"open_library_id"` from `build_book_attrs/4` | RED — `an Open Library hit stores open_library_id, and the provenance agrees`: *"the upload path dropped the Open Library id it had just been handed"* (`moderation_test.exs:128`), 35 tests 1 failure |
| drop `"google_books_id"` from `build_book_attrs/4` | RED — `a Google Books hit stores google_books_id, and the provenance agrees`: *"the upload path dropped the Google Books id it had just been handed"* (`moderation_test.exs:157`) |
| drop `"open_library_id"` from `update_primary_edition/2` | RED — `enrichment stores the cross-reference id its provenance claim is read off (#346)`: *"enrichment resolved the ISBN and threw the cross-reference away"* (`enrich_book_job_test.exs:180`) |

*Wiring trace.* Every insert path into `op.book_editions` now carries both ids:
`create_work/2` → `edition_attrs/2` (books.ex:240-241), `insert_edition/5`
(books.ex:976-977), `EnrichBookJob.update_primary_edition/2` (this change). The
seed's `castable_edition_row/1` and the test factory do not — see findings.

*Out-of-scope findings (not fixed here).*
1. The issue's Wiring section says the ids "become visible via `ProtoJSON.edition/1`, which already serialises them". It does **not** — its `Map.take` list carries `verification_source` but neither id. Nothing on the wire changes; the fix is observable via `verification_source` (derived) and `wh.stg_book_editions`.
2. `priv/repo/seeds.exs:659` hardcodes `verification_source: "open_library"` with no `open_library_id`, so every seeded edition builds a state no production write path can now produce — the exact rule books.ex:1135 cites from #329. 200 such rows in staging and local.
3. Nothing in the schema forbids `verification_source IN ('open_library','google_books')` with both id columns NULL. A CHECK would have made this bug unrepresentable, but it cannot be added until the 40 prod rows are backfilled (migration + ordering — its own issue).

**staff-review verdict: LGTM** (2026-07-31, lead, Mode B on 4791cef6). Praise: (a) the **null sweep is forensic, not just a count** — 40/40 production editions carry neither identifier, yet 38 carry a resolver-supplied `publication_year`, 17 a `publisher`, 17 a `cover_image_url`, and *all of those travel in the same metadata map as the two ids*. That proves the payload reached the row and exactly two keys were dropped, rather than the resolver having returned nothing; (b) it extended scope to `EnrichBookJob.update_primary_edition/2` **with a stated reason and stayed honest about it** — the barcode fast path resolves no metadata, so `Moderation` has no id to carry there; that job *is* the OL/GB round-trip for those rows, and it was writing the `verification_source` claim while discarding the two ids the claim is derived from. Without it the fix would have reached none of the dominant upload path; (c) the `verification_source` decision is better than the issue asked for — it **derives** everywhere except the barcode fast path, because the old code computed the claim from the *resolver metadata map* while writing a *different* map, "and two maps allowed to disagree is precisely how this bug hid". The fast path still states it, because `used_fast_path` is the one fact about that row no column records; (d) it **declined `Stacks.DataCorrection`** with the right reasoning: `run_corrections/1` executes inside Fly's `release_command` via `Release.deploy/0`, so 40 Open Library round-trips in `plan/0` would put a third-party outage in the path of every deploy — inverting #339's whole purpose — and would never converge for a permanently unresolvable ISBN.
**Lead independent verification — the production consequence is real and confirmed.** Queried production directly (`square-art-39019825`): **40 editions total, 40 with neither identifier, 40 with a real (non-placeholder) title.** Migration `20260730200000` stamps `ELSE 'barcode_unverified'` when both id columns are null, and `frontend/src/Types/Book.elm:205` renders provisional on exactly `verificationSource == "barcode_unverified"`. So deploying this campaign as-is marks **100% of the production catalogue "Not yet identified"** — every one of which is a correctly identified book. Raised to the owner as a deploy-sequencing decision; see the batch notes.
**Findings accepted:** (1) this issue's own Wiring section was **wrong** — `ProtoJSON.edition/1`'s `Map.take` carries `verification_source` but neither id, so nothing on the wire changes; the fix is observable via the derived provenance and `wh.stg_book_editions`. Corrected here rather than left to mislead. (2) `seeds.exs:659` hardcodes `verification_source: "open_library"` with no `open_library_id`, building a state no production path can now produce — the same class #329 closed for factories and #339 for seed ISBNs. (3) No schema guard forbids `verification_source IN ('open_library','google_books')` with both ids NULL; a CHECK would make the bug unrepresentable but cannot land until the 40 rows are backfilled.
Probes: 3/3 red, each on its own assertion. Suites: **3343/0**, credo clean.
