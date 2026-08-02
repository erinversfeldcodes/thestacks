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
- [ ] Endpoint live; token usable — evidence: test name + preview drive
- [ ] No-enumeration proven by response-to-response comparison — evidence: the three captured responses
- [ ] Rate limit applied without leaking existence — evidence: test + reasoning
- [ ] Erasure interplay decided and implemented, with the choice stated — evidence: diff + rationale
- [ ] Mutation probe on the no-enumeration assertion — evidence: transcript
- [ ] Live-driven end to end — evidence: screenshots
- [ ] `gdpr-review` verdict cited
- [ ] `staff-review` verdict recorded below

## Dependencies
Child of **#317**. Depends on **#316** (Arrival/notice components — complete). ⚠️ **Merges before #374**,
which shares `Login.elm`. Reason: file ownership, not logic.

## Agent Assignment
elixir-agent (endpoint, rate limit, job interplay) + elm-agent (affordance).

## Progress Notes
Filed 2026-08-01 by the lead at Wave 7 kickoff, from #317 phase 1.
