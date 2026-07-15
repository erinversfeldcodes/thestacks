# Issue #223: Public-profile browse — remaining P3 polish

## Summary
Small P3 items from the #210 review, grouped. None block merge; each is a
self-contained polish.

## Items
1. **Age-gate live E2E row.** `e2e/tests/public-profile.spec.ts` drives owner-only
   vs platform live and now the block→404 + ghost-404 wire rows, but NOT the
   age-gate spine-suppression row. Place a known age-gated seed book (e.g. ISBN
   9780140449242 "Demons") on a platform shelf, then assert an unverified/anon
   viewer's `count == 0` (no gap) and a verified viewer's `count == 1`. Pin the
   *visible* book to a known non-age-gated ISBN so the spine assertion is
   deterministic (today it trusts the first `per_page=1` catalogue result).
   (Age-gate is already asserted at the controller layer — this is the live row.)
2. **`BookshelfReadOnlyTest` hardening.** Assert zero PUT/DELETE of ANY URL after a
   read-only load (not just no "Add shelf"); add a `Page.Search` test for a
   readers-search `Failure` rendering the error banner and a 401 raising
   `SessionExpired`.
3. **`BookshelfName` custom type.** The profile-shelf route is stringly-typed
   (`Route.ProfileShelf String String`), diverging from the typed owner-shelf
   routes. Consider a `BookshelfName` type parsed at the Route boundary and reused
   by both, so label/theme/apiName mapping lives in one total function (removes the
   `profileConfig` snake_case fallback + the duplicated `shelfLabel`).
4. **Anonymous people-search reachability.** `/search` is auth-only in the SPA, so
   the optional-auth people-search backend is never exercised anonymously. Decide
   whether anonymous people-search is in scope; if yes, add `/search` to the
   non-auth routes.

## Definition of Done
- [ ] Items addressed or explicitly declined with a note.

## Source
platform/elm/ux reviewers (P3), #210 epic review.
