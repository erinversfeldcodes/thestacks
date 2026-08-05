# Issue #373: A reader who loses the confirmation email has no way back, and is erased at 24h

## Summary
Wave 7 child (7a) of epic **#317**, phase 1. Registration sends one confirmation email. If it is lost,
filtered, or mistyped, there is **no resend affordance anywhere** — the register-success card tells the
reader to register again, which cannot work because the email is already taken. `ExpiredUnverifiedAccountsJob`
then erases the unconfirmed account at 24h. So the recovery path is "wait a day, then start over", and
nothing on screen says so.

## User Stories
US-14.4.2 (resend confirmation) — to be mapped by #320.

## Goal
A reader who never received the email can ask for another one, and cannot be silently erased before they
have had that chance.

## Scope Check
One new endpoint + one affordance + the job interplay. Within scope (1 controller, 1 endpoint, ~200 LOC).

## Wiring
Router: `POST /api/auth/resend-confirmation`. UI: the registration-pending / login card affordance.

## Technical Requirements
1. **`POST /api/auth/resend-confirmation`** issuing a fresh confirmation token for an unconfirmed account.
2. **⚠️ No-enumeration is the load-bearing property.** The response for a real unconfirmed address, a real
   *confirmed* address, and an address with no account must be **byte-identical** — same status, same body,
   same headers. A test that asserts only "returns 200 for a real email" cannot detect a leak; the assertion
   must compare the three captured responses to each other.
3. **`:auth`-bucket rate limit**, consistent with login/forgot-password. ⚠️ Rate-limiting must not become an
   enumeration oracle either — being limited faster for real accounts leaks the same fact.
4. **Reconcile with `ExpiredUnverifiedAccountsJob`.** An account must not be erased while a freshly-requested
   confirmation is still live. Either extend the TTL on resend or document the interplay in the story —
   ⚠️ decide deliberately and write down which, because "the resend worked but the account vanished an hour
   later" is a worse experience than no resend at all.
5. **Replace the "register again" copy** on the registration-pending card with the resend affordance, in voice.

## Reviewer Context
- ⚠️ Read `Page/Login.elm`'s `Arrival` type (#360) before adding a state — the arrival notices are a closed
  union deliberately, and one arrival means at most one notice. Add a constructor rather than a boolean.
- ⚠️ **`Login.elm` is contended in this wave** — #374 also edits it (forgot-password double-send). This child
  merges **first**; #374 rebases onto it. Two agents in one Elm module is a merge conflict by construction
  (the #343/#344 lesson, re-confirmed in Wave 6).
- The forgot-password flow is the closest working exemplar of the no-enumeration shape — read it first.
- `gdpr-review` applies: this is an auth endpoint touching retention.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| API | yes | ❌ resend happy path issues a usable token |
| Security | yes | ❌ **no-enumeration**: three responses captured and asserted identical to each other |
| Security | yes | ❌ rate-limit does not differ by account existence |
| Elixir | yes | ❌ TTL/erasure interplay — a resent token survives the job |
| Elm | yes | ❌ affordance renders on the pending card; "register again" copy gone |
| E2E | yes | ❌ lose-the-email → resend → confirm journey via the sent-emails helper |
| Live drive | yes | ❌ driven on preview, screenshot |

## Definition of Done
- [x] Endpoint live; token usable — evidence: `POST /api/auth/resend-confirmation` with the positive
      control test (`the resent token confirms the account` family) green; preview drive below
- [x] No-enumeration proven by response-to-response comparison — evidence: the test compares FOUR
      captured responses (unconfirmed / confirmed / unknown / past-the-resend-cap, the case where the
      server does least work), asserts them pairwise equal, then pins the shared answer (200 +
      "fresh link" + content-type) so the equalities cannot be satisfied by everything converging on
      a 500 — and keeps a positive control so an endpoint that ignores its input cannot pass
- [x] Rate limit applied without leaking existence — evidence: `rate limiting is not an oracle: a
      real and an unknown address are throttled identically`; reasoning on the action itself — the
      `:auth` bucket is keyed per-IP and consumed BEFORE the action, so the limiter cannot become the
      oracle the body refuses to be; the per-user mail cap lives BEHIND the uniform response
- [x] Erasure interplay decided and implemented — evidence: the choice is **a resend rescues the
      account**: `a resend rescues an account the reaper was about to erase`
      (expired_unverified_accounts_job_test), and the no-enumeration test's fourth case covers the
      mirror (an account PAST the cap gets no link and stays indistinguishable)
- [x] Mutation probe on the no-enumeration assertion — evidence: reintroduced the leak in the
      controller (branch on `get_user_by_email`, different message for a real account) → exactly 1
      failure: "A real address and an address with no account answered differently"; reverted → 67/67
      (2026-08-04 transcript in the wave log)
- [x] Live-driven end to end — evidence: preview `stacks-core-pr-feat-campaign-w7-317.fly.dev`,
      2026-08-04. Logged OUT, `/resend-confirmation` renders the resend card (screenshot) — the
      `requiresAuth` fix holding, the exact door this feature opens; a dead link no longer bounces to
      a sign-in the reader cannot complete. Live no-enumeration proven at the wire: a real minted
      account and `definitely-not-real-9x@example.com` returned **byte-identical** 200 bodies
      (`diff` clean, 74 bytes each), and three unknown addresses all returned the same. ⚠️ The
      SPA-submit acknowledgement could not be confirmed by browser driving — a synthetic Elm submit
      threw a false negative (the notice appeared absent), which a ProgramTest disproved: any 200
      maps to `Success ()` and renders the notice, and the new `deadLinkResendIsAcknowledged` test
      pins it. The reliable oracle, not the browser, is the evidence here
- [x] `gdpr-review`: n/a to new data — no schema change; the endpoint reads existing accounts and
      issues an existing confirmation link. The GDPR-relevant behaviour is the *reconciliation* with
      erasure (a resend rescues an account the reaper was about to delete), tested and cited above.
      No personal data enters event_log/audit/warehouse. Stated, not skipped.
- [x] `staff-review` verdict recorded below

## Dependencies
Child of **#317**. Depends on **#316** (Arrival/notice components — complete). ⚠️ **Merges before #374**,
which shares `Login.elm`. Reason: file ownership, not logic.

## Agent Assignment
elixir-agent (endpoint, rate limit, job interplay) + elm-agent (affordance).

## Progress Notes
Filed 2026-08-01 by the lead at Wave 7 kickoff, from #317 phase 1.

## Progress Notes (review)
- 2026-08-04: **staff-review: LGTM.** The uniform-response design is genuinely uniform and I checked
  it three ways — byte-identical live bodies, the four-way response-equality test with a pinned shared
  answer and a positive control, and a mutation probe that reintroduced the leak (branch on
  `get_user_by_email`) and failed exactly the enumeration assertion. The rate limiter is not an
  oracle (per-IP, consumed before the action). The most useful part of the review was a caution about
  my own method, recorded in `deadLinkResendIsAcknowledged`: a synthetic browser submit reported the
  acknowledgement missing, and a ProgramTest disproved it — the drive was the unreliable witness, not
  the code. Coverage gap (no test proved the dead-link success render) closed as a side effect.
