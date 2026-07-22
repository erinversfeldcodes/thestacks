# Issue #272: E2E `empty-shelves` Seed User — Make Empty-State Tests Deterministic

## Summary
Four empty-state E2E assertions in `e2e/tests/bookshelf.spec.ts` (`:77`, `:90`, `:101`, `:127`) are
wrapped in `if ((await emptyText.count()) > 0)` and **have asserted nothing since March 2026**. Every
seeded E2E suite user gets 5 library / 3 antilibrary / 2 reading_pile placements
(`apps/core/priv/repo/seeds.exs:719`), so `.shelf-row__empty-text` never renders and the guard is
permanently false. There is no cleanup endpoint to empty a shelf at test time. This issue adds a
dedicated **`empty-shelves` seed suite user** with zero placements so those assertions can run
unconditionally.

## User Stories
- US-1.6.5 — per-shelf empty states (the wording asserted by the revived tests)

Unblocks #112 punch item #19.

## Goal
A suite user exists whose five bookshelves are all genuinely empty, so each shelf's empty-state
message can be asserted **unconditionally** — and a regression that stopped the empty state rendering
would fail a test rather than silently pass.

## Scope Check
- Does this issue touch more than 3 controllers? No — no controllers.
- Does this issue add more than 2 new endpoints? No — no endpoints (deliberately: a reset endpoint
  was considered and rejected as a larger, riskier surface).
- Does this issue exceed ~300 lines of production code? No — roughly 4 lines across two files.
- Does this issue combine unrelated concerns? No.

## Wiring
Router wiring: implementation-only (test fixture data + Playwright suite registration). Consumed by
#112 Phase 1.

## Feature-Completeness Pre-Check
n/a as a *feature* — this issue builds no user-facing behaviour. **But note** (per the orchestrator's
"do not trust the issue's self-classification" rule): this fixture exists to make US-1.6.5's empty
states *provable*, so US-1.6.5's empty-state rendering **is** in scope for a live drive here. It is
covered by the proving gate in the DoD below, not waved through as infra.

## Technical Requirements
- Add one slug (e.g. `empty-shelves`) to `Seeds.e2e_suites()` (`apps/core/priv/repo/seeds.exs:30`)
  and the matching entry to `E2E_SUITES` (`e2e/tests/helpers.ts:35`), so it gets its own storage-state
  file via `suiteAuthFile` (`helpers.ts:17`) and is authenticated by `auth.setup.ts`.
- **Exclude it from the placement `flat_map`** at `seeds.exs:726` so it inherits bookshelves (created
  at `seeds.exs:649`) but **zero placements**.
- Do not add a shelf-reset test-helper endpoint. The three existing `STACKS_E2E_TEST_HELPERS` routes
  (`apps/core/lib/core_web/router.ex:383-387`) are deliberately narrow; an additive seed user is the
  cheaper and safer route.
- WishList and Looking-for-Home are *already* empty for every suite user — those two assertions can go
  unconditional without this fixture. This issue is what unblocks **Library / AntiLibrary / Reading
  Pile**.

### Deliverable protection (the #110 lesson)
This deliverable is a **fixture**, and a fixture that silently stops producing its state is exactly the
failure class that a passing E2E suite hides. Therefore:
- The seed logic must remain in the existing testable `Seeds` structure — do not inline raw rows in a
  way that no test can reach.
- The proving gate is **not** "the seed file changed" or "a unit test passes". It is: run the seed,
  authenticate as the new user, browse each of the five shelves, and **observe the empty-state text
  render** — the real signal at the far end.

## Reviewer Context
- The `if (count > 0)` guards this issue removes are **vestigial, not load-bearing**: they were added
  in `6e5d6d7a3` (14:23) and the per-suite seeded users that made them unnecessary landed in
  `c41ab528` (15:36) — 73 minutes later. Removing them restores intended behaviour.
- Empty-state selector is `.shelf-row__empty-text` for the bookcase shelves. Looking-for-Home uses
  `Components.EmptyBookshelf` (`Page/Bookshelf/LookingForHome.elm:12,99`) — the **only** page that
  does; the unified page has its own local `viewEmptyShelfMessage` (`Page/Bookshelf.elm:350`).
- Exact expected wording lives in `issues/112-e2e-shelf-browsing.md:104-108`. Looking-for-Home's
  (`"Nothing here yet — these are books looking for a new home."`) is confirmed verbatim at
  `LookingForHome.elm:102` — note the **en dash**.
- Adding a suite user shifts the `user_idx` arithmetic (`shelf_base`, `place_base` at `seeds.exs:726-728`).
  Verify existing suite users' data is unchanged — an off-by-one here would silently re-point other
  suites' fixtures.

## Test Audit
Compact format — fixture issue.

| Layer | Applies? | Verdict |
|-------|----------|---------|
| E2E (browser) | yes | ❌ → ✅ — five unconditional empty-state assertions (one per shelf) with **no** `if (count > 0)` guard |
| DB / seed integrity (L3) | yes | ❌ → ✅ — the new user has 0 placements and 5 bookshelves; existing suite users' placement counts unchanged |
| dbt (L9) | no | n/a — dev-fixture rows only; no staging model or contract change |
| 1–2, 4–8, 11–13 | no | n/a — no API, auth, event, job, external service, storage, cache, metric or cost surface |

## GDPR
n/a — **stated as a positive finding, not skipped.** This adds a synthetic dev/test-fixture user to
`seeds.exs`. It introduces no new personal-data column, no new user-data endpoint, no event payload
and no dbt model, and it never runs against production data. Erasure/export reachability is unchanged.

## Definition of Done
- [x] `empty-shelves` suite user added to `Seeds.e2e_suites()` and `E2E_SUITES` — evidence: `apps/core/priv/repo/seeds.exs:47` `{25, "empty-shelves", "E2E Empty Shelves"}` + `e2e/tests/helpers.ts:41`; new `Seeds.e2e_empty_suites/0` allowlist (`seeds.exs:55`)
- [x] User is excluded from the placement `flat_map` and has zero placements — evidence: `Enum.reject(... slug in Seeds.e2e_empty_suites())` at `seeds.exs:745` ahead of the placement `flat_map`; SQL count for the new user = 0 placements / 5 bookshelves
- [x] Existing suite users' placement counts unchanged (5/3/2) — evidence: per-user md5 over ordered `(bookshelf, position, book_id, placement_id)` tuples **byte-identical** before/after (`diff` exit 0, all 15 pre-existing users); insert path exercised via full delete + re-seed
- [x] **Proving gate:** authenticated as `e2e-empty-shelves@thestacks.test`, all five shelves browsed live (`BASE_URL=http://localhost:4000`), empty-state text observed rendering — evidence: 5 verbatim captures (Library "Your library is waiting…", AntiLibrary "Books you own but haven't read yet…", WishList "Books you're dreaming about…", Reading Pile "Nothing on the pile right now…", Looking for Home "Nothing here yet — these are books looking for a new home." — en dash confirmed)
- [x] All five empty-state assertions run **unconditionally** — evidence: grep for `if ((await …count()) > 0)` in `bookshelf.spec.ts` / `reading-pile.spec.ts` / `looking-for-home.spec.ts` → **no matches**; all seven prior guards removed
- [x] Each assertion **fails** if the empty state stops rendering — evidence: 3 break-and-observe runs (placements added to the empty-shelves user → all 5 bookshelf.spec assertions fail; placements added to looking-for-home user → that assertion fails; reading pile emptied → 3 reading-pile.spec assertions fail)
- [x] Every behaviour has a validation path — evidence: the de-guarded E2E assertions above; two masked defects also fixed (armchair selector `.reading-pile__armchair`→`.armchair`; onboarding overlay obscuring the page, now seeded away with an `afterEach` overlay-count-0 guard)
- [x] `just verify` passes — evidence: `just run just verify` EXIT 0 (2749 elixir / 940 elm / 233 dbt); committed `06e8dd65`

## Dependencies
- Local PostgreSQL + seeded DB
- Blocks: #112 punch item #19 (Phase 1)

## Agent Assignment
`elixir-agent` (seed), `testing-coordinator` / `playwright` (spec de-guarding + drive).
Reviewer: `elixir-reviewer` + `database-reviewer` (seed arithmetic).

## Progress Notes

### 2026-07-21 — elixir-agent — implemented

**Seed fixture.** Added `{25, "empty-shelves", "E2E Empty Shelves"}` to `Seeds.e2e_suites/0` plus a new
`Seeds.e2e_empty_suites/0` allowlist, and rejected those slugs from the placement `flat_map`. The user
inherits 5 bookshelves and 0 placements. `"empty-shelves"` added to `E2E_SUITES` (`helpers.ts`).

**Seed arithmetic is position-independent — no off-by-one risk.** `shelf_base`/`place_base`/`offset` are
all derived from `user_idx` (`400 + (user_idx - 10) * 10`), not from list position, so appending a suite
cannot re-point existing fixtures. Proven empirically: an md5 over each suite user's ordered
`(bookshelf, position, book_id, placement_id)` tuples is **byte-identical before and after** for all 15
pre-existing users; all remain 5 library / 3 antilibrary / 2 reading_pile. New user: 5 bookshelves, 0 placements.

**Proving gate (live, `BASE_URL=http://localhost:4000`).** Authenticated as `e2e-empty-shelves@thestacks.test`
and browsed all five shelves; empty-state text observed rendering on each, consoles clean, screenshots
captured to `e2e/test-results/272-empty-*.png`.

**Guards removed (8 total, all proven non-vacuous by deliberately breaking each fixture and observing the
failure):** `bookshelf.spec.ts` ×4 (+1 new Looking-for-Home assertion), `reading-pile.spec.ts` ×3, plus two
tautological assertions rewritten (`reading-pile.spec.ts` "empty reading pile" and `looking-for-home.spec.ts`
"pile view or empty state" — both were `expect(a || b).toBeTruthy()` over always-present elements).

**Masked defect confirmed and fixed.** `reading-pile.spec.ts`'s armchair assertion used
`.reading-pile__armchair`, which matches **0 elements** — the live DOM emits `class="armchair"`
(`ReadingPile.elm:137`). Measured live: old selector → 0, new selector → 1. Corrected the selector rather
than re-adding the guard.

**Second defect, caught only by the screenshot (the proving gate earning its keep).** The first live drive
went green while the empty states were **covered by the first-run onboarding overlay** — a zero-placement
user is precisely who `shouldShowOnboarding` (`Main.elm:2845`) targets, and `toContainText` does not
require visibility, so the assertions passed against an obscured page. A text-only or count-only check
would have shipped this. Fixed by seeding the empty-suite user with
`onboarding_steps: %{"profile" => true, "privacy" => true}` (`onboarding_completed` is a generated column
over those keys), restoring the invariant `onboarding.spec.ts:13` documents — no *seeded* user shows the
overlay; that spec mints its own user and is unaffected. A `test.afterEach` now asserts
`onboarding-overlay` has count 0 so the regression fails loudly instead of hiding. Re-drive screenshots
confirm all five empty states render unobscured.

**Note for whoever runs the suite next:** `shelf-actions.spec.ts` mutates its own suite user's placements
(antilibrary 3→5, wishlist 0→2 observed after a full run) and `on_conflict: :nothing` means a re-seed does
not restore them. Pre-existing fixture-design property, unrelated to this issue, but it makes raw
before/after placement counts misleading unless taken around the seed alone.
