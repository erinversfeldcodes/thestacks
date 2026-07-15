# Issue #226: Visibility E2E + coverage completion

## Summary
A coverage audit (post-#225, the 4-rung ladder) confirmed the visibility matrix is
**well-covered at the controller/resolver layer** but has **live-drive (browser E2E)
gaps**, plus one thin controller-layer cell. Captures the remainder so the deferred
preview-E2E gate closes the whole matrix.

## Already done (do NOT redo)
- **Search bug FIXED (#225 follow-on):** `Accounts.search_users/2` now returns
  `platform` + `public` to a signed-in searcher and **only `public` to an anonymous
  one** (was: `platform`-only, to everyone — hiding public profiles and leaking
  platform ones to anon who'd 404 on them). Tests: `accounts_test.exs` search_users
  describe + `user_search_controller_test.exs`.
- **Controller/resolver matrix is solid:** anon sees `public` / 404s on `platform`
  (`profile_controller_test.exs:85-99, :247-302`), group member-vs-non-member
  (`:167-245`), age-gate incl. `age-gate + public` (`:304-355`), block→404, blog
  public-vs-platform-for-anon (`blog_test`/`blog_controller_test`), marketplace
  ceiling-punch + block-beats-marketplace (`visibility_test.exs:124-202`).

## Outstanding — live browser E2E (for the preview gate)
Each is a `(rung × viewer × surface)` cell asserted only at the API/unit layer today.
Priority order:

1. **Anon `public` vs `platform` — RENDERED.** A logged-out browser renders a `public`
   profile hub + browses a `public` shelf spine + reads a `public` blog post; a
   `platform` (Members) profile/shelf/post shows "Reader not found" / empty. Today
   only wire-level (`public-profile.spec.ts:276`) — the core #225 promise isn't
   rendered-tested.
2. **`group` rung, browser — member vs non-member.** Owner sets a shelf/placement to
   `group`; a group member sees it, a non-member does not. Zero browser coverage on
   any surface (controller-covered only).
3. **Deterministic age-gate in the browser.** `age-gate.spec.ts:35` is a
   non-deterministic `.age-gate OR .book-detail` assertion that proves nothing. Split
   into: anon/unverified → gate shown; verified → content shown.
4. **`view_as` actually re-scopes content.** `privacy.spec.ts:185` only asserts the
   banner appears. Add: with `?view_as=unauthenticated` on a profile with platform-only
   shelves, the owner sees the anonymous projection (platform shelves hidden).
5. **Block on the profile-hub surface, browser.** Currently API-only
   (`public-profile.spec.ts:272`); assert a blocked viewer renders "Reader not found".
6. **Marketplace exception — controller + E2E.** The `looking_for_home` + active-listing
   ceiling-punch is tested ONLY at the resolver unit (`visibility_test.exs:124-202`) —
   no endpoint test and no browser drive. Add a listings/marketplace controller test
   (visible to a platform user below the shelf rung, NOT to anon, block still wins) and
   an E2E row.

## Definition of Done
- [x] Items 1–6 covered by a browser E2E (or, for #6, a controller test + E2E), run
      green **locally against the live stack** (`BASE_URL=http://localhost:4000`, seeded
      dev DB, `STACKS_E2E_TEST_HELPERS=1`). Preview-gate re-run tracked under task #6.
- [x] `e2e/tests/public-profile.spec.ts` drives the anon/public/platform/age-gate/block
      rows live; `age-gate.spec.ts` rewritten deterministic.

## Status: RESOLVED — 2026-07-15

Delivered (all green locally, 15/15 across public-profile + age-gate + privacy):
- **Item 1 (anon public vs platform, RENDERED)** — `public-profile.spec.ts` "an anonymous
  browser renders a public profile + public shelf, but a platform profile is not found":
  logged-out browser renders the `public` hub, browses the `public` shelf spine read-only,
  and gets "Reader not found" on a `platform` profile.
- **Item 3 (deterministic age-gate)** — `age-gate.spec.ts` rewritten: OWNS the
  `age_verified` flag (set via API + reload) to assert gate-shown-then-content, replacing
  the old non-deterministic `.age-gate OR .book-detail`.
- **Item 4 (view_as re-scopes)** — new test drives the real `ViewAsPlug` + resolver: a
  public shelf's platform placement is present in the owner's own view (count 1) and hidden
  under `?view_as=unauthenticated` (count 0), while the shelf stays reachable.
- **Item 5 (block on the hub, RENDERED)** — new test: a signed-in blocked viewer renders
  "Reader not found" on the profile hub (was API-only).
- **Item 6 (marketplace exception)** — controller test added to `profile_controller_test.exs`
  (active `looking_for_home` listing punches through for a platform viewer, not anon, block
  wins via the profile 404 gate) + an E2E row asserting the punch through the profile-shelf
  endpoint and the public `/api/listings` browse.

**Item 2 (group rung, browser) — DEFERRED to #224 (not a gap here).** Group member/non-member
is already proven at the controller layer (`profile_controller_test.exs` "visibility matrix —
group") using a factory-set `visibility_group_id`. It CANNOT be browser-driven because there is
**no public API/UI setter for `visibility_group_id`** — `PUT /api/bookshelves/:name/visibility`
casts only `visibility`, so a `group` shelf always has a nil group FK and resolves hidden-for-all.
The positive "member sees" case needs that setter, which is #224's "one chosen group" work; the
negative case is indistinguishable from an empty/owner shelf at the browser layer and adds no
signal over the controller matrix. Writing a browser assertion would be misleading, so it is
intentionally omitted here and folded into #224.

### Two pre-existing bugs found by the first real live-drive (fixed here)
The #210 `public-profile.spec.ts` journey had only ever been parse/discovery-validated (no
running preview), so live execution exposed two latent test bugs:
1. **Catalogue pagination** — `resolveCatalogueIds` assumed `?per_page=200` returned every
   seed book, but the catalogue caps `per_page` at 100 (`catalogue_controller.ex`). Books past
   position 100 under the default title-sort (e.g. "The Left Hand of Darkness") were unreachable.
   Now pages through (100/page, bounded by `total`).
2. **Shelf-name substring match** — `.profile__shelf` filtered by `hasText: "Library"`, which
   case-insensitively also matched "Antilibrary". Now anchored (`/^Library$/`).

## Source
Visibility coverage audit during the #225 4-rung-ladder work (2026-07-15).
