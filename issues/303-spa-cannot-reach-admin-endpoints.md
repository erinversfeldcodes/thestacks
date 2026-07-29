# Issue #303: The SPA cannot reach any admin endpoint — no admin-session/MFA flow exists

## Summary
Every admin page in the Elm SPA sends the **regular** Guardian token to endpoints behind the
`:admin` pipeline, which requires a separate MFA-verified admin session (`typ: "admin_session"`)
and rejects anything else with 401. All four admin surfaces are therefore unreachable in the
browser, regardless of role.

## User Stories
None named directly. It blocks the operator surfaces for US-2.5.3 (removal-request review),
source approval, scraper health, and age-gate book moderation (#118).

## Goal
An owner can reach the admin surfaces from the SPA: authenticate an admin session, verify MFA,
and have admin API calls carry the admin token — with the regular session untouched.

## Scope Check
- More than 3 controllers? → No new controllers; `AdminAuthController` already exists.
- More than 2 new endpoints? → **Zero new endpoints.** `POST /api/admin/auth/login`,
  `/auth/verify_mfa`, `/auth/mfa/setup`, `/auth/mfa/confirm` and `DELETE /auth/logout` all exist
  and work (driven, see Progress Notes).
- More than ~300 lines? → Borderline. An MFA/admin-login page plus token plumbing through four
  pages. **Split if it grows:** (a) admin session + login/MFA screen and token storage,
  (b) repoint the four existing pages onto it.
- Unrelated concerns? → No.

## Wiring
Router wiring: includes wiring — user-facing on completion. The Elm routes exist
(`/admin/sources`, `/admin/scrapers`, `/admin/book-moderation`, `/admin/removal-requests`); what
is missing is the auth path that lets them load.

## Feature-Completeness Pre-Check
n/a — no named user stories. ⚠️ But note the shape: four surfaces are **built, routed, tested and
unreachable**. Any audit that ticked them off from code or unit tests was measuring the wrong
thing; the wiring trace breaks at the auth layer, one level below every one of those pages.

## Technical Requirements

**The break.** `frontend/src/` contains **zero** matches for `admin_session`, `adminToken`,
`verify_mfa` or `mfa`. `Main.elm` passes the ordinary `maybeToken` into
`AdminSourceApproval.init`, `AdminScraperConfig.init`, `AdminBookModeration.init` and
`AdminRemovalRequests.init`, and each calls e.g. `Api.getAdminSources … token`. But
`apps/core/lib/core_web/router.ex` routes `/api/admin/*` through `pipeline :admin` →
`AdminAuthPipeline` (requires `typ: "admin_session"`, validates the session is unrevoked,
unexpired, and **IP- and boot_id-matched**) → `RequireMFA` (verified within 30 minutes).

**The server side already works** — driven end to end on a preview:

1. `POST /api/auth/login` → ordinary token
2. `POST /api/admin/auth/mfa/setup` (ordinary owner auth) → `provisioning_uri`, `recovery_codes`
3. `POST /api/admin/auth/mfa/confirm` → `{ok: true}`
4. `POST /api/admin/auth/login` → `{session_id}`
5. `POST /api/admin/auth/verify_mfa` → `{token}` ← the admin token
6. `GET /api/admin/removal-requests` → 200

So this is a **client** issue. Do not add endpoints.

✅ **The encoding trap in step 3 is FIXED (2026-07-29), not documented around.** `mfa_confirm`
demanded base64 of the raw secret bytes, while `mfa_setup` publishes the secret only as **base32**
inside the provisioning URI — so no client could satisfy it without decoding and re-encoding, and
getting it wrong returned `422 invalid_code`, which reads as clock skew. The endpoint now accepts
base32, i.e. exactly what its own setup call hands out.

⚠️ **Why the tests missed an impossible contract, which is the transferable part:** every
`mfa_confirm` test called `MFA.begin_enrollment/1` **directly** to get raw secret bytes, then encoded
them however the endpoint wanted — **bypassing the contract a client is forced to use**. A test that
walks the client's path (setup → read `secret=` from the URI → confirm unmodified) now exists and is
mutation-probed: it fails against `Base.decode64/1`. When a test constructs its input by a route no
caller can take, it is testing the implementation, not the interface.

## Design (decided 2026-07-29, during Wave 0 execution)

**The admin token is held in memory only — in `Main.Model` — and is never persisted.** No new port,
no localStorage, no sessionStorage.

Three reasons, in order of weight:

1. **It needs no port at all**, which honours the project's "no ports unless absolutely necessary"
   rule. Persisting it would mean a `saveAdminAuth`/`clearAdminAuth` pair, JS wiring in
   `apps/core/assets/js/app.js`, sibling-tab sync (the `stacks-auth` path already carries that
   complexity for #180), and a clearing path on logout. In-memory removes all of it.
2. **The credential is the highest-value one in the system** and localStorage is readable by any
   XSS. An admin token that dies with the page is a much smaller target.
3. **It is already short-lived and fragile by design**: MFA expires after 30 minutes, and the
   session is bound to both the client IP and the node's `boot_id`. Persisting a token that a
   machine restart or a network change invalidates buys little.

The cost is that a page reload requires re-authenticating. For an operator surface entered
deliberately and occasionally, that is acceptable — and it is the honest consequence of the token
being short-lived anyway.

**Shape:**
- `Main.Model` gains `adminAuth : Maybe AdminAuth` (token + expiry).
- An `/admin/*` route with `adminAuth == Nothing` renders an **admin sign-in gate** rather than the
  page — so the four admin pages never see a token they cannot use, and never render an error state
  that means "you are not signed in".
- The four pages take the **admin** token, not `maybeToken`. That is the actual bug: they were
  handed the ordinary Guardian token, which the `:admin` pipeline rejects with 401.
- **MFA expiry (30 min) surfaces as a re-verify prompt over the current page**, not a logout: the
  ordinary session is untouched, so losing admin rights must not eject the operator from the app.
- An **IP change** invalidates the session server-side and returns 401. It surfaces as the same
  re-verify prompt with a plain explanation, since "your network changed" is the real cause and a
  generic "signed out" would send the operator looking for a different problem.

## Reviewer Context
- ⚠️ `PUT /api/admin/sources/:id/approve` **publishes** a listing;
  `PUT /api/admin/removal-requests/:id/honour` **takes one down**. Same-sounding verbs, opposite
  effects, same row. Keep them visually and textually distinct in any shared admin chrome.
- `fly secrets deploy` is required for staged secrets; a machine restart does not apply them, and
  restarting invalidates sessions via the `boot_id` claim (expect to re-authenticate).
- The preview Neon branch is **deleted and recreated from staging on every deploy**, so MFA
  enrolment and any seeded rows do not survive a redeploy. Re-run the enrolment flow each time.

## Test Audit

| Layer | Applies? | Verdict |
|-------|----------|---------|
| API calls (Elm → admin endpoints) | yes | ❌ no coverage — the four pages' happy path is untested against the real pipeline |
| Auth & middleware guards | yes | ⚠️ server side covered (`AdminAuthPipeline` / `RequireMFA` tests); the client contract is not |
| Elm state machine | yes | ❌ no admin-session state exists to test |
| Others (DB, Oban, storage, cache, dbt, cost) | no | n/a — client auth plumbing only |

Punch list:
1. An E2E spec that reaches **one** admin page in a browser with a real MFA-verified session.
   This is the assertion that would have caught the whole class — every existing admin test
   passes a token straight to a mocked API, which is why four dead pages looked fine.
2. An Elm test that an admin API call carries the **admin** token, not `stacks-auth`'s.
3. A test for the 30-minute MFA expiry path (re-verify, no state loss).

Verdict: ❌ — nothing currently exercises the client→admin-pipeline boundary.

## Definition of Done
- [x] An owner can reach all four admin pages in a browser — evidence: driven on a clean preview
      2026-07-29 with screenshots of each: Source Approval (5 rows, Approve/Reject rendering),
      Scraper Health (3 sources with Healthy/Degraded/Broken badges), Book Moderation (50 rows with
      `Mark age-gated`), Removal requests (1 row, then empty after honouring)
- [x] Admin API calls carry the admin token; the regular session survives admin-session expiry —
      evidence: XHR trace `admin/auth/login 200 → verify_mfa 200 → GET /api/admin/sources 200 →
      PUT .../approve 200 → GET /api/admin/removal-requests 200 → PUT .../honour 200`, and on a real
      401 the app showed the **admin gate**, not `/login`, with `stacks-auth` intact
- [x] An admin action completes end to end, not merely a page load — evidence: `PUT .../approve 200`
      moved a row `Pending_review → Approved`; `PUT .../honour 200` emptied the queue and the DB shows
      `status=excluded`, `excluded_at` set, `exclusion_email` retained, `third_spaces.opted_out=true`
- [x] The base32/base64 secret trap is fixed rather than documented around — evidence:
      `admin_auth_controller.ex` now `Base.decode32/2`; `admin_auth_controller_test.exs` "accepts the
      secret exactly as `mfa_setup` publishes it — the client's real path", mutation-probed (fails on
      `Base.decode64/1`)
- [x] `just verify` passes — evidence: `VERIFY8_EXIT=0`, 3180 Elixir tests / 1285 Elm tests / dbt
      checkpoint clean / elm-review clean
- [x] **An E2E spec reaches an admin page with a real MFA-verified session** — evidence:
      `e2e/tests/admin-session.spec.ts`, **7/7 green** against the deployed preview 2026-07-29
      (`--workers=1`). It implements RFC 6238 TOTP in Node and drives the gate's own form, so it
      exercises the real `:admin` pipeline rather than a mock. Its five assertions map one-to-one onto
      the four stacked bugs: gate-not-page without an admin session; the page loading WITH rows;
      Approve/Reject rendering on a pending source; an admin **action** changing state (not merely a
      page load); and an admin 401 returning to the gate with `stacks-auth` intact.
**De-scoped (not a DoD item):** *MFA re-verify loses no page state.* `handleAdminSessionExpiry`
      puts the gate on the current route and re-resolves that route after re-auth, so the operator
      returns to the same *page* — but its internal state (filter tab, pagination) resets, because the
      page model is replaced by the gate's. Preserving it would mean keeping a page model alive
      alongside the gate for a 30-minute-expiry path on an operator surface. Not worth the complexity;
      recorded here so it stops being re-raised as a gap.

## Progress Notes
- 2026-07-28: Found while trying to drive the new removal-request queue
  (`/admin/removal-requests`) on a preview. A fresh owner token returned **401** from
  `GET /api/admin/sources` — the *pre-existing* page's own endpoint — which is what showed this
  is systemic and not specific to the new page.
  Proved the server half works by driving the full MFA flow by hand (steps above), then exercised
  the queue end to end: approve source → `POST /api/opt-out` from a mismatched domain → the
  request appears in the queue with its contact address → `honour` → `200 {"outcome":"removed"}`
  → queue empty → second `honour` → **409** (not 404). DB confirmed
  `third_spaces.opted_out = true`, `discovered_sources.status = 'excluded'`.
  So: server verified live, client unreachable. See
  `plans/staff-campaign-2026-07-27.md` → "The SPA cannot reach any admin endpoint".
