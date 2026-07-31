# Staff Engineer Campaign — Remediation Plan
**Date:** 2026-07-26 · **Scope:** Phase 1 (extended) — Auth, Navigation, Errors, Settings, Accessibility

## The frame

**Make Phase 1 (extended) genuinely launch-ready — verified rather than claimed — so the closed beta
can invite real users who are able to recover their own accounts.**

`notes/phase-1-launch-extension.md`: Milestone A is verification-first because "claimed complete ≠
verified" (lines 10–20); Milestone D gates the closed beta on account recovery (line 83, "needed the
moment real users forget passwords or lose the confirmation email"); line 31 lists account recovery
among the known user-facing gaps.

**Ordering principle** (from line 41, *"budget for the fixes, not just the tests"*): prove what is
real, then fix what blocks the beta, then pay down the drift that makes the next change expensive.

## Coverage — read this before trusting the plan

| Area | Surveyed | Driven live | Tests probed |
|---|---|---|---|
| Story census (22 claimed + §14–19 sweep) | ✅ mechanical | n/a | n/a |
| Elixir auth/accounts/session/settings | ✅ full design pass | partial | ✅ 1 probe |
| Elm auth/nav/settings/errors | ✅ full design pass | partial | ❌ |
| Test suites (Elixir + elm-test + E2E) | ✅ full inventory + coverage map | n/a | ✅ 1 probe |
| `frontend/css/main.css` token drift | ✅ mechanical | ❌ | n/a |
| Routes / pages / workers / tables | ✅ reverse inventory | partial | n/a |

**Authenticated drive: RESOLVED — it was never a tooling gap.** My first attempt failed because I
wrote the auth blob **nested** (`{token, user:{…}}`); the app reads it **flat**
(`{token, userId, email, displayName}`) — exactly as `e2e/tests/helpers.ts:375-392` (`injectSession`)
writes it and as `apps/core/assets/js/app.js:167,176` reads it ("top-level, as written to
localStorage"). With the correct shape, minting via `POST /api/test/session` + a flat `localStorage`
write + a reload authenticates the SPA fine. **The capability exists and works; only the shape was
wrong.** Two consequences:

1. **No plan item is needed to *enable* authenticated drives.** The recipe is: mint → write the flat
   blob → reload. It is now recorded here and in Wave 0.
2. **The reason I got no feedback is a finding, promoted below (ROOT 3).** `decodeFlags`
   (`Main.elm:433-436`) discards a malformed auth blob via `Result.toMaybe` with no diagnostic, so a
   mis-shaped stored session is indistinguishable from being logged out. I hit that failure mode
   exactly as a user with corrupted `localStorage` would, and silently drew the wrong conclusion
   from it. That is the cost of the swallow, measured.

**What I still did NOT do — the plan's remaining edges:**
- **The drive was local, not preview.** No delivery-path evidence (assets, seeds, config, cold
  start). All creds are present (`FLY_API_TOKEN`, `NEON_STAGING_*`) — this was a cost choice.
- **The authenticated drive was targeted, not exhaustive.** I drove the settings hub, the Password
  and Consent pages, and the session-expiry A/B (below). The shelves, upload, book detail,
  marketplace, onboarding beyond "Skip", and 15-odd other journeys were **not** driven — those
  verdicts stay PARTIAL.
- **No coherence sweep across many surfaces, no mobile viewport, no full empty/error-state tour.**
- **Only 1 mutation probe** (the reset-token guard). Other test verdicts come from inventory +
  coverage-mapping, not probes.

So: **well-evidenced on code, tests, and the two flows I drove; thin on the rest of the experiential
axis.** Wave 0 is still mandatory before trusting a UX-shaped conclusion about an undriven surface.

## Reconnaissance numbers

| Metric | Value |
|---|---|
| Elixir suite baseline | **2,957 tests, 15 properties, 0 failures, 10 excluded** (156s) |
| Story census (phase table) | 22/22 have a story file **and** a mapping section |
| Story files in §14–19 vs mapped | **24 exist, 22 mapped** → `US-14.4.1`, `US-14.4.2` unmapped |
| Routes in `core_web/router.ex` | 132 (the only router; `stacks_web/router.ex` does not exist) |
| Elm routes / pages | 34 route constructors; 4 rendered inline in `Main.elm` (Home, About, ConfirmEmail, NotFound) |
| `Main.elm` | 3,054 lines · 51 `Msg` · 35 `Page` constructors |
| Oban workers | 29 defined, **4 with no enqueue path** |
| Settings pages handling 401 | **3 of 6** (Consent, Privacy, AuditLog) |
| CSS | 41 distinct tokens, **89 hardcoded hex literals**, **3 phantom tokens**, no spacing scale |
| E2E specs in scope | 8 files; **0 vacuous count-guards** in them |

## Root findings (clustered by cause, ranked by leverage)

### ROOT 1 ⛔ — Account recovery is incomplete, and the guarantees it does have are untested
**Leverage: highest.** Directly blocks Milestone D. Security + product, and cheap relative to impact.

| Symptom | Evidence |
|---|---|
| Reset-token **single-use** untested | Probe: replaced `email.ex:93` `Repo.get_by(User, id: user_id, password_reset_token: token)` with `…id: user_id)` → **76 tests, 0 failures**. That match *is* the single-use mechanism (`do_reset_password` nils the token, `email.ex:156`), so a consumed token stays valid for its full 24h. Independently confirmed by the coverage map: "NONE FOUND". |
| Reset-token **supersession** untested | No test requests two resets and tries the stale first token. |
| **Password reset does not revoke sessions** | `email.ex:150-163` never calls `Accounts.revoke_all_user_sessions/1`, while the authenticated change-password path *does* (`user_settings_controller.ex:64-68`). A reset leaves an attacker-held session alive — the opposite of what reset is for. |
| **Resend confirmation does not exist** | No route, action, page, or test. The app's own copy admits the consequence: "Please register again to receive a fresh confirmation email" (`Main.elm:3033-3035`). Only other escape is the 24h reaper erasing the account. |
| Rate-limited reset **silently reports success** | `email.ex:108-134` never binds the `with :ok <- check_rate_limit(...)` result; returns `:ok` regardless. User and controller both see success; no email sent. |
| Email-confirm **expiry** untested | Only the reset path has an expiry test (`email_test.exs:117-125`). |
| Both stories **unmapped** | `US-14.4.1`, `US-14.4.2` appear nowhere in `implementation-mapping.md`. |
| Issue **#191 is stale** | Claims "no frontend, and the reset email links to a route that doesn't exist". Both false: `Page/ResetPassword.elm` is wired (`Main.elm:68,210,835`; `Route.elm:105`) and the email builds `/reset-password/#{token}` (`email_delivery_job.ex:113`) which the parser matches. Its real remaining scope is resend + the missing tests. |

### ROOT 2 ⛔ — Session-expiry handling is a per-page convention, so pages silently opt out
**Leverage: high — a ladder climb that eliminates a whole defect class.**
**Status: CONFIRMED BY LIVE A/B DRIVE** (not code-reading).

**The A/B, same revoked session, same 401:**

| Page | Request | Status | What the user gets |
|---|---|---|---|
| `/settings/password` | `PUT /api/settings/password` | **401** | *"Could not change password. Please try again."* — **stays on the page.** Retrying can never succeed. Dead end. |
| `/settings/consent` | `POST /api/gdpr/consent` | **401** | **Redirects to `/login`** with *"The library closed your session for safekeeping — sign in again to return."* Correct behaviour. |

Method: minted a session, revoked it server-side (`DELETE /api/auth/logout` → 204; `/api/auth/me`
→ 401, i.e. a real mid-session expiry), then submitted each form. Screenshots captured. The only
difference between the two outcomes is whether the page's author remembered the convention.

| Symptom | Evidence |
|---|---|
| 3 of 6 settings pages cannot signal expiry | Verified counts — `Password`/`Profile`/`Notifications`: **0** `isUnauthorized`, **0** `OutMsg`, `update` arity-2. `Consent`/`Privacy`/`AuditLog` have all three. Confirmed live above. |
| No test covers the gap | `SessionExpiryPagesTest.elm`'s own describe says "the 6 remaining authed pages" — among settings it covers only Consent and Privacy. |
| The convention is copy-paste | 9 near-verbatim `isUnauthorized → SessionExpired` repetitions across 3 files. |
| Unauth treatment is inconsistent | **Drive:** `/` redirects to `/login`; `/library` and `/settings/password` render the login card **in place**, keeping the URL and the page title ("Library — The Stacks", "Password — The Stacks") while showing a Sign In form. |

### ROOT 3 🟧 — "Why are you at /login?" is 3 booleans + a runtime priority chain
**Leverage: medium-high — a ladder climb that also fixes a user-visible copy bug.**

`Main.elm:273,278,283` has independent `sessionExpiredNotice` / `draftSavedNotice` /
`accountDeletedNotice`; `Login.elm:55,60,64` mirrors them. Nothing prevents "session expired" and
"account deleted" both being true, so `UrlChanged` resolves it with an explicit priority if/else
(`Main.elm:1230-1242`). `pendingAuthResponse` (`Main.elm:264`) duplicates `Login.transitionState`,
forcing a defensive catch-all (`Main.elm:1369-1370`). One `LoginRedirectNotice` custom type makes all
of it unrepresentable. **Drive evidence it matters:** arriving at `/` with **empty localStorage**
(verified) showed *"The library closed your session for safekeeping — sign in again to return."* to a
visitor who never had a session. (The same notice is *correct* after a real expiry — confirmed in the
ROOT 2 A/B — so this is a trigger bug, not bad copy.)

**Promoted into this root — the silent-flag-decode swallow.** `decodeFlags` (`Main.elm:433-436`) uses
`Result.toMaybe` on the stored-auth decode, so a malformed `stacks-auth` blob is silently
indistinguishable from "logged out": no console warning, no diagnostic, no recovery prompt. **I hit
this myself during this campaign** — a mis-shaped injected session produced a clean login screen and
I wrongly concluded authenticated drives were impossible. A real user with corrupted `localStorage`
gets the same silent logout with no way to know why. Fixing it is one branch: log/surface the decode
failure and clear the bad key deliberately rather than treating it as absence.

### ROOT 4 🟧 — The same knowledge is written down several times, inconsistently
**Leverage: medium. Economy, and one correct exemplar already exists to copy.**

Password-reset TTL hardcoded twice (`email.ex:91` literal `86_400`; `templates.ex:49` prose) while
its twin, the confirm TTL, is properly centralised via `Accounts.unverified_account_ttl_seconds/0`
and read by three consumers — **the right pattern is already in the file next door.** Also: three
independent `{n, unit} → seconds` implementations, two with **no catch-all** so an unknown unit
crashes (`auth_controller.ex:355-359`, `guardian_token_sweep_job.ex:80-84`); rate-limit comment says
"3/min" while the constant is 20/60s (`router.ex:290` vs `rate_limiter.ex:64`); the 8-char and
passwords-match rules implemented 3× with 3 different messages; 4 copies of the save-button state
machine; 2 independent session-minting sequences (`auth_controller.ex:62-93` vs
`test_helper_controller.ex:368-397`); 3 URL-construction sites with no builder.

### ROOT 5 🟧 — Invariants live in application code where the database could hold them
**Leverage: medium — the highest-value rungs available.**

`auth_token_families.user_id` and `guardian_tokens.sub` have **no FK** (`auth_token_families.ex:24`;
migration `20260711000000:29`) — self-acknowledged in `deletion.ex:199-201`. `users.email` is unique
**exact-match**, not `lower(email)`, while `handle` correctly has a `lower()` unique index — so
case-duplicate identities are DB-legal even though lookup downcases (`accounts.ex:283-286`, comment
at `810-822`). `password_reset_token` / `password_reset_sent_at` are independently nullable with no
`CHECK`. Lockout's three columns have no consistency constraint.

### ROOT 6 🟨 — Dead and unreachable code (pure deletion)
4 Oban workers with **no enqueue path**: `ConfirmDeletionJob` (a stub that only logs — its 3 tests
assert `:ok`, proving only that the stub doesn't crash), `DiscoverBookstoreEventsJob`,
`FetchReviewsJob`, `RecalculateWearJob`. `Page/ThirdSpaces.elm` is orphaned (no route, no import) yet
`GET /api/third-spaces` is live. `Route.Settings` is a parser branch nothing ever produces, with a
verbatim-duplicated init (`Main.elm:644-654` vs `656-666`). `LogoutCompleted` is a no-op whose
`Result` is discarded via `always` (`Main.elm:2168`) — a failed server-side logout is invisible.
3 phantom CSS tokens (`--link-color`, `--link-hover`, `--parchment-ink`) are `var()`-referenced but
never defined. 6 routes have no nav entry (Groups, GroupDetail, `/blog` root, `/costs`, `/metrics`,
`/u/:handle`).

### ROOT 7 🟨 — Design-token drift
89 hex literals vs 20 colour tokens; two `var()` fallbacks that **contradict their own token**
(`--radius-sm, 0.25rem` vs actual `2px`; `--parchment-border, #c4b69c` vs actual
`rgba(44,31,14,0.12)`); a third un-tokenised gold `#d4a029` sitting between the two gold tokens; two
rival error reds (`#e05050`, `#b03030`); **no spacing scale exists at all**, so every padding/margin
is a literal. *(Checked and cleared: the green `Forgot your password?` link is `#4a7c59` — the real
`--accent` token, used correctly. Not drift.)*

## Ladder wins — defects moved from "a test might catch it" to "it cannot happen"

| Finding | Caught today at | Could be caught at | Class eliminated |
|---|---|---|---|
| Page forgets 401 handling (ROOT 2) | Nothing (rung 8 — silent) | Rung 1-2: one authed-request wrapper returning a type that *must* be handled | Every future page silently opting out |
| Notice booleans (ROOT 3) | Runtime priority chain | Rung 2: custom type = compile error | Contradictory notices, wrong copy |
| Missing FKs (ROOT 5) | App-code deletes only | Rung 4: FK + cascade | Orphan token rows from any future write path |
| Case-duplicate emails (ROOT 5) | Nothing | Rung 4: `lower(email)` unique index | Duplicate-identity accounts |
| reset_token/sent_at pairing (ROOT 5) | Convention in one caller | Rung 4: `CHECK` | Half-set reset state |
| `{n,unit}` crash on unknown unit (ROOT 4) | Rung 7 crash | Rung 3: one impl + Dialyzer | Config-typo crashes |

## The plan

### Wave 0 — Finish the evidence (do this first; it is cheap and it gates the rest)
**Why first:** the experiential axis is thin for the ~18 journeys I did not drive, and Waves 3–5
change user-facing flows. Drive before you rebuild.

**The authenticated-drive recipe** (verified working this session — no tooling work needed):
```bash
# 1. stack with helpers on
AGE_GATING_ENABLED=true STACKS_E2E_TEST_HELPERS=1 MIX_ENV=dev just run mix phx.server
# 2. rebuild assets first — mtime staleness is a false signal, but check content:
rm -rf apps/core/assets/elm/elm-stuff && (cd apps/core/assets && node build.js --production)
```
Then in the browser, at the app origin:
```js
const s = await (await fetch('/api/test/session',{method:'POST',
  headers:{'Content-Type':'application/json'},
  body:JSON.stringify({email:'drive-'+Date.now()+'@thestacks.test'})})).json();
// FLAT shape — nesting under `user` fails silently (see ROOT 3)
localStorage.setItem('stacks-auth', JSON.stringify(
  {token:s.token, userId:s.user_id, email:s.email, displayName:s.display_name}));
location.reload();
```
To simulate expiry mid-session: `DELETE /api/auth/logout` with that token, then act in the UI.

| Item | Size |
|---|---|
| Preview deploy + authenticated drive of the ~18 undriven journeys; coherence sweep; empty/error/mobile states | S–M |
| Record the recipe above in `e2e/README` or `CLAUDE.md` so the next drive doesn't rediscover the shape | XS |

### Wave 1 — Deletions (shrink before refactoring)
**Why first among code changes:** never refactor or test code you're about to delete.
| Issue | Root | Size |
|---|---|---|
| Delete 4 never-enqueued workers + their tests, or wire them if wanted (decide per worker; `ConfirmDeletionJob` is a stub — delete) | 6 | S |
| Delete `Page/ThirdSpaces.elm` **or** wire it to a route (backend endpoint is live — this is a product call, not a cleanup) | 6 | S |
| Remove `Route.Settings` dead branch + its duplicated init; remove `LogoutCompleted` no-op or make the logout failure visible | 6 | S |
| Delete the 3 phantom CSS tokens (replace `var()` with the literal, or define them) | 7 | XS |

### Wave 2 — Contracts and constraints (they ripple outward; land them early)
**Why here:** migrations gate everything downstream, and squawk runs in CI (`just ci`, not `just verify`).
| Issue | Root | Size |
|---|---|---|
| FKs on `auth_token_families.user_id` + a real owner for `guardian_tokens.sub`; drop the app-code compensation in `deletion.ex` | 5 | M |
| `lower(email)` unique index + downcase-on-write; reconcile existing duplicates first | 5 | M |
| `CHECK` on the reset-token/sent-at pair; lockout-column consistency | 5 | S |

### Wave 3 — Security guarantees for account recovery (the beta blocker)
**Why here:** needs Wave 2's constraints; must precede Wave 4's new flow.
| Issue | Root | Size |
|---|---|---|
| **Password reset must revoke all sessions** (mirror `user_settings_controller.ex:64-68`) + test | 1 | S |
| Tests for reset-token **single-use** and **supersession** (my probe is the specification: break the guard, these must go red) | 1 | S |
| Fix the silent-`:ok` rate-limited reset; surface it honestly + test | 1 | S |
| Test email-confirm token expiry | 1 | XS |

### Wave 4 — Build resend confirmation (US-14.4.2)
**Why here:** it is the remaining *feature* gap in recovery, and it should be built on Wave 3's now-correct token semantics. One endpoint + Login-card affordance + rate limit; scoped already in #191.
| Issue | Root | Size |
|---|---|---|
| `POST /api/auth/resend-confirmation` + UI + no-enumeration + rate limit + tests; replace the "register again" copy | 1 | M |

### Wave 5 — Make session-expiry structural (the ladder climb)
**Why here — and why NOT earlier:** ⚠️ **Do not write per-page 401 tests before this wave.** Those
tests would be deleted by the refactor. Land the structural fix, then test the structure once. This
is the sequencing rule in action.
| Issue | Root | Size |
|---|---|---|
| One authed-request wrapper whose result type forces 401 handling; migrate all 6 settings pages + the 9 duplicated guards onto it | 2 | M |
| Replace the 3+3 notice booleans with a `LoginRedirectNotice` custom type; delete the priority chain; fix the first-visit copy bug | 3 | M |
| Surface the `decodeFlags` decode failure instead of swallowing it (log + deliberately clear the bad key) | 3 | XS |
| Make unauth treatment consistent: one behaviour for `/` and `/library`-class routes (redirect + correct title) | 2 | S |

### Wave 6 — Economy / dedup
| Issue | Root | Size |
|---|---|---|
| Centralise the reset TTL (copy the `unverified_account_ttl_seconds/0` pattern); one `{n,unit}` impl with a catch-all; fix the 3/min-vs-20 comment | 4 | S |
| One password-validation module (length + match, one message set); one save-button component; one settings page-chrome wrapper | 4 | M |
| Collapse the two session-minting sequences to one shared function | 4 | S |

### Wave 7 — Documentation and discoverability
| Issue | Root | Size |
|---|---|---|
| Map `US-14.4.1`/`US-14.4.2` into the phase row, §14, and the Oban inventory; rewrite #191's stale summary | 1,5 | S |
| Correct mapping line 1857's settings list (`Privacy` in; `Export`/`Delete`/`AgeVerification` out — the last is ADR-020 §2, a deliberate exclusion) | 5 | XS |
| Decide + act on the 6 no-nav routes: link them or mark them deliberately URL-only | 6 | S |

### Wave 8 — Token drift (batch; cheap and objective)
| Issue | Root | Size |
|---|---|---|
| Fix the 2 contradictory `var()` fallbacks; tokenise the third gold + pick one error red; replace literals that duplicate a token | 7 | S |
| Introduce a spacing scale (none exists) — or record explicitly that spacing is deliberately untokenised | 7 | M |

## Deliberately not in this plan

| Item | Why |
|---|---|
| Age-gate Verify affordance / `Page.Settings.AgeVerification` | Withdrawn by ADR-020 §2; provider flow is #069. The stale *mapping reference* is in Wave 7; the code's absence is correct. |
| Splitting `Main.elm` (3,054 lines) | The repetition is the load-bearing cost of per-page `OutMsg` typing — Elm gives no free way to collapse it. Wave 5 removes some of it as a side effect. Re-evaluate after; don't split on line count (Czaplicki, *Life of a File*). |
| Community moderation, POSSE, vision redesign | `notes/` places them outside this phase (Milestone D defers moderation explicitly; vision is gated on the eval harness). |
| Keyboard-nav expansion beyond Escape + 2 focus traps | Real gap (US-19.1.2 is thin), but out of the beta-blocking frame. Should become its own tracked issue, not a wave here. |

## What this costs and what it buys

Roughly **20 issues across 8 waves**, front-loaded with cheap deletions and ending in cheap batches.
The expensive middle is Waves 3–5 (recovery security, the resend feature, the session-expiry
refactor) — call it the bulk of the effort, and it is the part that actually unblocks the beta.

At the end: a user who forgets their password or loses their confirmation email can recover without
support, and cannot be locked out or replayed against; a session expiring anywhere in the app lands
the user back at login instead of a dead form; contradictory notice states and orphan token rows are
unrepresentable rather than merely unobserved; and roughly a dozen files' worth of dead code, phantom
tokens, and duplicated rules are gone. The phase becomes honestly describable as verified — which is
what `notes/` says Milestone A is for.
