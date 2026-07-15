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
- [ ] Items 1–6 covered by a browser E2E (or, for #6, a controller test + E2E), run
      green in the preview gate.
- [ ] `e2e/tests/public-profile.spec.ts` (or a new `visibility-matrix.spec.ts`) drives
      the anon/public/platform/group/age-gate/block rows live.

## Source
Visibility coverage audit during the #225 4-rung-ladder work (2026-07-15).
