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

⚠️ **Encoding trap in step 3, which cost real time:** the provisioning URI carries the TOTP
secret as **base32** (the standard), but `mfa_confirm` runs `Base.decode64/1` on the `secret`
param — so the client must base32-decode the URI secret and **base64-encode the raw bytes**.
Sending the base32 string through returns `422 invalid_code`, which reads as a clock-skew or
wrong-code problem and sends you looking in the wrong place. Either document this at the
endpoint or accept base32 — the current pairing is a trap for whoever writes the client.

**Design questions for the implementer (not decided here):**
- Where does the admin token live? It must **not** replace `stacks-auth`, or an expiring admin
  session would log the operator out of the app. A separate key, or an in-memory-only field.
- MFA expires after 30 minutes while the regular session does not. The UI needs a re-verify path
  that does not lose page state.
- The admin session is **IP-bound**. A mobile network switching IP mid-session will 401; decide
  whether that surfaces as "sign in again" or something clearer.

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
- [ ] An owner can reach all four admin pages in a browser — evidence: live-drive screenshots of
      each, on a preview, with rows rendered
- [ ] Admin API calls carry the admin token; the regular session survives admin-session expiry —
      evidence: Elm test + a live drive showing the app still usable after MFA lapses
- [ ] MFA re-verify path exists and loses no page state — evidence: named test + live drive
- [ ] E2E spec reaches an admin page with a real MFA-verified session — evidence: spec name +
      captured run output
- [ ] The base32/base64 secret trap is either fixed or documented at the endpoint — evidence: the
      committed diff
- [ ] `just verify` passes — evidence: command → captured output

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
