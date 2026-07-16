# Issue #229: Hide age-gated books from the catalogue for unverified users + reconcile US-4.2

## Summary
Owner design decision: age-gated books must be **hidden from listing surfaces** (catalogue, search,
bookshelf) for users who are not age-verified — anonymous **or** authenticated-but-unverified — while
a **direct URL** to an age-gated book detail shows a block-and-explain UI (the existing 403 age gate).
Search, the public-profile shelf, and the owner shelf already honour this (they route through
`Stacks.Visibility`, which resolves `age_verified`). The **catalogue is the sole gap**: it hides
age-gated books from anonymous users only, so an authenticated-but-**unverified** user still sees them.
This issue closes that gap and reconciles US-4.2, whose written model still describes the superseded
"frosted overlay / lock icon on the spine" (visible-but-obscured) behaviour.

## User Stories
US-4.2 (Age Verification for Gated Content). Child of epic **#118**.

## Goal
An authenticated-but-unverified user sees **no** age-gated books in the catalogue (as they already
don't in search / on shelves); a verified user sees them; a direct URL still 403s with the
block-and-explain UI. US-4.2 documents the hide-from-listings + block-on-detail model as the source
of truth (the frosted-overlay language is removed).

## Scope Check
- More than 3 controllers? **No** — one (`CatalogueController`); the fix is mostly in `Books`.
- More than 2 new endpoints? **No** — none.
- Exceeds ~300 LOC production? **No** — thread an age-verified signal into `list_catalogue` + one
  extra `maybe_exclude_age_gated` clause (~40 LOC) + tests + a doc edit.
- Combines unrelated concerns? **No** — one behaviour (hide age-gated from the catalogue for
  unverified viewers) + the doc that specifies it.

## Wiring
- [x] This issue includes wiring and is user-facing when complete (changes what the catalogue
      endpoint returns to a real unverified user).
- [ ] Implementation only.

## Feature-Completeness Pre-Check
US-4.2 is **built** but its listing-hiding behaviour is **🟡 partial** — correct on 3 of 4 surfaces,
with the catalogue's authenticated-unverified path a real gap. Per the Pre-Check rule this is a
build-in-scope resolution (this issue), not a Test-Audit reclassification.

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-4.2 — Age verification (listing hiding) | Search `search_controller.ex:16` → `Visibility.can_view?` ✅ · Profile shelf `profile_controller.ex:74` → `filter_visible_placements` `visibility.ex:468` ✅ · **Catalogue `catalogue_controller.ex:36` → `Books.list_catalogue` → `maybe_exclude_age_gated` `books.ex:497-501` — filters `:unauthenticated` only ❌** · Detail gate `age_gate.ex:42` 403 ✅ | 🟡 catalogue shows age-gated to authed-unverified users | 🟡 partial (catalogue gap) | **build in-scope (this issue)** |

Verdict: ✅ implemented · 🟡 partial (enumerate missing hops) · ❌ missing.

## Technical Requirements

### 1. Close the catalogue gap (`apps/core/lib/stacks/books.ex` + `catalogue_controller.ex`)
- The catalogue uses a SQL predicate (`maybe_exclude_age_gated`, `books.ex:497-501`) — necessary so
  `total`/pagination counts are correct (an in-memory post-filter would break paging). It currently
  only knows `:unauthenticated`.
- Thread the viewer's age-verified status into `list_catalogue`. The full `user` struct (with
  `.age_verified`) is already in hand at `catalogue_controller.ex:39` — only `id` is forwarded today.
  Options (pick in the design step): pass `{:platform_user, id}` + an `age_verified:` opt, or a
  3-tuple viewer, or load the flag into opts. Preserve SQL-level filtering.
- Add a `maybe_exclude_age_gated` clause that ALSO emits `where visibility_tier != "age_gated"` for an
  **authenticated-but-unverified** viewer; leave verified users unfiltered.
- Do **not** regress: an owner viewing their OWN age-gated book elsewhere is a separate, owner-scoped
  surface (not the catalogue) — the catalogue is a stranger listing, so unverified-owner is also
  filtered here (confirm this is acceptable; the owner still reaches the book via their shelf/detail).

### 2. Reconcile US-4.2 (`docs/user_stories/US-4.2-age-verification.md`)
- Replace the "frosted overlay / lock icon on the spine" display model (lines 9, 16) with the
  **hide-from-listings + block-on-detail** model: age-gated books are omitted from catalogue/search/
  shelf listings for unverified users; a direct URL yields a 403 + the `.age-gate` block-and-explain UI.
- Add an acceptance criterion for the listing-hiding behaviour across all four surfaces + the
  verified-user reveal.
- Record the decision (this supersedes the original spec) — a one-line note in the story plus, if the
  project uses `docs/decisions/`, a short ADR-style entry.

### 3. Regression coverage for the already-correct surfaces
- Add/confirm a test that search and the profile shelf continue to hide age-gated from an
  authenticated-unverified viewer and reveal them to a verified one (they route through `Visibility`;
  lock the behaviour so a future `Visibility` change can't silently regress it).

### 4. Resolves #118 §1 wording
- This issue's model replaces #118 Technical Requirements §1 ("frosted overlay and lock icon on
  age-gated spines"). #118 core will rewrite §1 to the hide-from-listings/block-on-detail assertions
  (tracked in the #118 core scope) — no orphaned frosted-overlay requirement remains.

## Reviewer Context
- The catalogue MUST filter at the SQL layer (not in-memory) so `total`/pagination stay correct —
  see `list_catalogue/1` and the `maybe_exclude_age_gated` predicate.
- `age_verified` is NOT carried in the `{:platform_user, id}` viewer tuple anywhere; `Stacks.Visibility`
  resolves it internally from `viewer_id` (`viewer_age_verified?/1`, `visibility.ex:255-260`). The
  catalogue bypasses `Visibility` by design (SQL predicate), so it needs its own age-verified signal.
- Design divergence: the owner decided age-gated content is **hidden from listings**, superseding
  US-4.2's written frosted-overlay model — this issue is where that decision is recorded.
- age-gate books are seeded via `moderation.ex` `determine_visibility_tier/1` (BISAC
  FIC005000/FIC027000/FIC069000); seed fixture ISBN `9780140449242` ("Demons") is age_gated.

## Test Audit

_Full format, US-4.2 (catalogue age-gate hiding), 13 layers × 1 US, happy/sad (26 cells) — E2E is a
framework row, not a cell. Generated 2026-07-15, grep/Read-verified on `feat/118-e2e`. The changed
behaviour is a read-path filter: L1 (catalogue API returns filtered) + L2 (age-verified guard on a
listing) + L3 (SQL predicate + pagination `total`). The detail gate, search, and profile shelf are
already ✅ (#118/#213) — inventoried here so the regression-lock work doesn't duplicate them._

Legend: ✅ real · ⚠️ shallow / adjacent-only · ❌ missing · n/a (reason)

### Feature status (code-verified) — 3 of 4 surfaces already correct; catalogue is the sole gap
- **Search — ✅** `search_controller.ex:16` filters hits through `Visibility.can_view?`; `check_age_gate/3` → `viewer_age_verified?/1` (`visibility.ex:242-260`) resolves the flag live, so authed-unverified is treated like anon.
- **Profile shelf — ✅** `profile_controller.ex:74` → `filter_visible_placements`; age-verification resolved once per request into the batch context (`visibility.ex:248-251`, #221 O(1) path).
- **Detail 403 gate — ✅** `age_gate.ex:42-59` (`enforce/2`) 403s anon+unverified, passes verified; Elm `.age-gate` block UI driven by it.
- **Catalogue — ❌ GAP.** `catalogue_controller.ex:36-40` maps any authed user → `{:platform_user, id}`, **discarding** the in-hand `user.age_verified`. `Books.list_catalogue/1` → `maybe_exclude_age_gated/2` emits `where visibility_tier != "age_gated"` only for `:unauthenticated` (`books.ex:497-499`); the catch-all `maybe_exclude_age_gated(query, _viewer)` (`books.ex:501`) returns the query **unfiltered** → an authed-**unverified** user sees every age-gated book. The predicate is SQL-level (`total` computed off `filtered`, `books.ex:465`) — must stay SQL-level for paging correctness.

### Framework-layer summary
| Layer | US-4.2 — catalogue hiding |
|-------|---------------------------|
| Elixir | ⚠️ CODE+TEST gap. Search (`search_controller_test.exs` 2 age-gate) + shelf (`profile_controller_test.exs` 2) ✅ for authed-unverified; catalogue (`catalogue_controller_test.exs`) tests anon-hidden + total + **verified**-shown, but **no authed-unverified-hidden** test, and code doesn't filter it. Detail ✅ (`age_gate_test.exs` 7, `book_controller_test.exs` age-gate 6). |
| Elm | n/a — server-side filter, no new Elm state/decoder. |
| Python / dbt | n/a — not involved / read-path filter, no model change. |
| E2E | ❌ no Playwright asserting the catalogue/search **listing** hides the seed book for an unverified browser + reveals after verify. **`age-gate.spec.ts:33-34` currently RELIES ON THE BUG** (locates the age-gated book from the catalogue as an authed viewer) — the fix breaks that lookup, so the fixture must be updated in the same change (punch #4). |

### Existing-test inventory (grep/read — regression-lock targets, not new work)
- **Search** `search_controller_test.exs:87` `"excludes age_gated books from results for non-age-verified user"`; `:105` `"includes age_gated books in results for age-verified user"`.
- **Profile shelf** `profile_controller_test.exs:304` `"an age-gated book is hidden from unverified/unauthenticated viewers, shown to verified"` (count 1 verified / 0 unverified `:329` / 0 anon `:330`); `:333` owner-of-own.
- **Detail** `age_gate_test.exs` (**7**, not 8 — refactored): `:18/:29/:36` 403 paths, `:45` verified passes, `:12/:55/:60` public/nil; `book_controller_test.exs` age-gate `:124/:136` (`/api/books/:id`), `:488/:502/:508/:515` (`/isbn/:isbn`).
- **Catalogue** `catalogue_controller_test.exs` (**12**): `:142` anon-hidden, `:155` `"total … accurate, not raw DB count"` (anon, SQL-level), `:167` `"authenticated user sees age_gated books in catalogue"` (`age_verified: true`, verified-shown). **Confirmed absent:** NO authed-**unverified**-hidden catalogue test — `:167` covers only the verified viewer.

### Full audit (13 layers × US-4.2, happy/sad)
| Layer | Happy | V | Sad | V |
|-------|-------|---|-----|---|
| 1 API | ✅ verified sees `catalogue_controller_test.exs:167`; anon hidden `:142` | ✅(v/anon) | ❌ **no authed-unverified-hidden** test; code doesn't filter (`books.ex:501`) | ❌ |
| 2 auth | ✅ adjacent verified `search…:105`, `profile…:328` | ✅(adj) | ❌ authed-unverified-as-anon rule untested/unenforced **at catalogue** (`catalogue_controller.ex:39`, `books.ex:501`) | ❌ |
| 3 DB | ✅ SQL predicate paging-safe for anon `:155` | ✅(anon) | ⚠️ new authed-unverified clause's `total` untested | ⚠️ |
| 4 event · 5 Oban · 6 external · 7 storage · 8 cache · 9 dbt | n/a — read-path filter, no event/job/external/storage/cache/warehouse | n/a | n/a | n/a |
| 10 Elm | n/a — renders the filtered list; outcome asserted at E2E | n/a | n/a | n/a |
| 11 metrics | n/a — SLO gate | n/a | n/a — enforce counts are #228 | n/a |
| 12 perf · 13 cost | n/a — one indexed `WHERE`, no external cost | n/a | n/a | n/a |
| **E2E** (framework row) | ❌ unverified catalogue hides seed → verify → appears → direct URL `.age-gate` (fixture at `age-gate.spec.ts:33-34` must be updated) | ❌ | — | — |

### Coverage tally
| ✅ | ⚠️ | ❌ | n/a |
|---|---|---|---|
| 4 | 1 | 2 | 19 |

26 cells + **1 ❌ E2E** framework row.

### Punch list (baseline — 0 resolved)
| # | Cell | What's needed | Where |
|--:|------|---------------|-------|
| 1 | L1/L2 sad (CODE) | Thread `age_verified` into `Books.list_catalogue/1` (full `user` already at `catalogue_controller.ex:39`); add a `maybe_exclude_age_gated` clause (`books.ex:497-501`) emitting `where visibility_tier != "age_gated"` for authed-unverified, at SQL layer so `total` (`books.ex:465`) stays correct. | `books.ex`, `catalogue_controller.ex` |
| 2 | L1/L3 sad (TEST) | Catalogue controller test both classes: `insert(:user, age_verified: false)` → age-gated absent + `total` excludes them (mirror `:155`); `age_verified: true` → present (extend `:167`); keep anon `:142`. | `catalogue_controller_test.exs` |
| 3 | L2 regression-lock | Annotate search (`search_controller_test.exs:87/:105`) + shelf (`profile_controller_test.exs:304-330`) age-gate tests as the regression lock. | `search_controller_test.exs`, `profile_controller_test.exs` |
| 4 | E2E (+ fixture fix) | Unverified catalogue/search hides seed ISBN `9780140449242` → verify → appears → direct URL `.age-gate`. **Update `age-gate.spec.ts:33-34`** which relies on the bug to locate the book (resolve id via verified-search or the isbn endpoint). | `e2e/tests/age-gate.spec.ts` (or new `age-gate-listing.spec.ts`) |
| 5 | Doc | Reconcile `US-4.2-age-verification.md:9,16` — replace frosted-overlay/lock-icon-on-spine with hide-from-listings + block-on-detail; add a listing-hiding acceptance criterion across all 4 surfaces + verified reveal; record the superseding decision. Hand #118 §1 supersession to #118 core. | `docs/user_stories/US-4.2-age-verification.md` (+ `docs/decisions/`) |

### Verdict
**Baseline — 4 ✅ · 1 ⚠️ · 2 ❌ + 1 ❌ E2E → 5 punch items (1 code, 1 catalogue test, 1 regression-lock,
1 E2E-with-fixture-fix, 1 doc).** Headline: 3 of 4 age-gate surfaces already correct via `Visibility`
(search / profile shelf / detail gate), each regression-tested; **the catalogue is the sole gap** —
`catalogue_controller.ex:39` discards `age_verified` and `books.ex:501`'s catch-all leaves authed-
unverified unfiltered, uncaught by any test (`catalogue_controller_test.exs:167` tests only verified).
US-4.2's written frosted-overlay model is superseded → reconcile. **Load-bearing coupling:** the E2E
`age-gate.spec.ts:33-34` relies on the bug to find the seed book — the fix breaks that lookup, fixture
updated in the same change. Totals (grep): `catalogue_controller_test.exs` **12** (3 age-gate, authed-
unverified-hidden absent), `search_controller_test.exs` **9**, `profile_controller_test.exs` **23**,
`age_gate_test.exs` **7**, `book_controller_test.exs` age-gate **6**, `age-gate.spec.ts` **1** (detail only).

## Definition of Done
- [ ] `GET /api/catalogue` omits age-gated books for an authenticated-unverified user and includes them for a verified user, with correct `total` — controller test proves both.
- [ ] Search + profile-shelf age-gate hiding for authed-unverified is regression-locked.
- [ ] US-4.2 reconciled to the hide-from-listings/block-on-detail model (frosted-overlay language removed; decision recorded).
- [ ] E2E: unverified catalogue hides the age-gated seed book → after verification it appears → direct URL shows the `.age-gate` block.
- [ ] `age-gate.spec.ts:33-34` (which currently locates the age-gated book via the catalogue as an authed viewer — i.e. depends on the bug) is updated to resolve the book id another way, so the E2E no longer relies on the leak the code fix closes.
- [ ] #118 §1 wording superseded (handed to #118 core).
- [ ] Feature-Completeness Pre-Check for US-4.2 is ✅ (catalogue gap closed).
- [ ] `just verify` passes; E2E green on the preview gate.
- [ ] Test audit (above) GREEN.
- [ ] Meets the Completion Bar — driven live (local first): an unverified browser sees no age-gated books in the catalogue.

## Dependencies
Touches `books.ex` (`list_catalogue`/`maybe_exclude_age_gated`, ~line 463-501) — a **different
function** from #227's event emit (~line 182), but the SAME FILE, so merge #227 before #229 to keep
the `books.ex` merge mechanical. Otherwise independent. Integration branch: `feat/118-e2e`.

## Agent Assignment
elixir-agent (catalogue filter + doc) + a design note; reviewers: elixir-reviewer + contract-reviewer
(catalogue response shape) + ux-reviewer (the hidden-vs-gated user experience). E2E via testing-coordinator.
