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

## Delegation spec (agent)
Do items 1, 2, 4 (concrete + low-risk). For item 3 (BookshelfName type), implement it if it
stays small/total; otherwise leave a short note in this issue declining it with the reason.
**Files:** `e2e/tests/public-profile.spec.ts` (item 1); `frontend/tests/Page/BookshelfReadOnlyTest.elm`
+ `frontend/tests/Page/SearchProgramTest.elm` (item 2); `frontend/src/Navigation/Route.elm` +
`frontend/src/Page/Bookshelf.elm` (item 3, optional); `frontend/src/Main.elm` routing + a
non-auth route entry (item 4).
**Acceptance criteria:**
1. **Age-gate live E2E row:** place a known age-gated seed book (ISBN `9780140449242` "Demons")
   on a platform shelf; assert unverified + anonymous viewers get `count == 0` (no shelf gap)
   and a verified viewer gets `count == 1`. Pin the *visible* book to a known NON-age-gated
   seed ISBN so the existing spine assertion is deterministic (stop trusting the first
   `per_page=1` catalogue result).
2. **Read-only test hardening:** in `BookshelfReadOnlyTest.elm` assert (a) a spine click in
   read-only mode dispatches NO navigation/mutation (look-only), (b) the owner-attribution
   back-link (`testId "shelf-attribution"` → `Route.Profile handle`) renders. In a Search test
   assert a readers-search `Failure` renders the error banner and a 401 raises `SessionExpired`.
3. **(optional) `BookshelfName` custom type** parsed at the Route boundary, reused by owner +
   profile-shelf routes, so label/theme/apiName live in one total function (removes the
   `profileConfig` snake_case fallback + duplicated `shelfLabel`). Decline with a note if it
   balloons.
4. **Anon people-search:** decide + act — either add `/search` to the non-auth routes so the
   optional-auth backend is exercised anonymously, OR document in this issue why anonymous
   people-search is out of scope. State which you chose.
**Verify:** `just run bash` → `npx elm-test` green; `e2e/tests/public-profile.spec.ts` parses
(`npx playwright test public-profile --list`); `just run just verify`.

## Source
platform/elm/ux reviewers (P3), #210 epic review.
