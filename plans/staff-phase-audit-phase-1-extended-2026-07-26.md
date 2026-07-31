# Staff Engineer Phase Assessment — Phase 1 (extended): Auth, Navigation, Errors, Settings
**Date:** 2026-07-26 · **Verdict:** GAPS
**Corpora:** mapping ✅ · stories ✅ · notes ✅ (present, main tree)

## Verdict in one paragraph

The phase's 22 claimed stories are in genuinely good shape — the census is clean (every one has both
a story file and a story-by-story mapping section, which is rarer than it sounds), the suite is
green at 2,957 tests, and the E2E specs for this surface are free of the vacuous `if (count > 0)`
guards that plague other specs in this repo. The problems are all at the **edges of the phase**, not
in its middle: two account-recovery stories that exist as files and are largely *built* are absent
from the mapping entirely; the settings sub-page list in the mapping describes a structure that no
longer matches the code; and one security guarantee in the password-reset flow has **no test at
all** — I removed it and all 76 relevant tests still passed. Crucially, **I did not drive this phase
live**, so per this project's own standard nothing below is rated COMPLETE.

## Coverage — read this before trusting anything else

| Area | Surveyed | Driven live | Tests probed | Notes |
|---|---|---|---|---|
| Story census (22 + section sweep) | ✅ mechanical | n/a | n/a | Objective; highest confidence |
| Password reset (US-14.4.1) | ✅ full code trace | ❌ | ✅ 1 probe | Probe found a real gap |
| Resend confirmation (US-14.4.2) | ✅ | ❌ | n/a | Nothing to probe — unbuilt |
| Settings sub-pages | ✅ | ❌ | ❌ | Drift found by inventory |
| Footer, nav, a11y, looking-for-home | ⚠️ presence-check only | ❌ | ❌ | Existence, not correctness |
| The other 18 stories | ⚠️ not individually assessed | ❌ | ❌ | **Not covered** |

**The drive was NOT performed.** Two subagent readers and the planned preview deploy were cut short
by credit exhaustion mid-audit. Per the Evidence Standard, a code-read does not establish "built" —
so **every built-verdict below is PARTIAL, none is COMPLETE**, and there is no coherence sweep, no
screenshots, and no empty/error-state assessment in this report. This audit is therefore
**incomplete by its own rules**, and its verdict should be read as "GAPS found so far", not "these
are the gaps".

## What I ran

| Command | Result | What it told me |
|---|---|---|
| `just run mix test` | **2,957 tests, 15 properties, 0 failures, 10 excluded** (156s) | Green baseline |
| `just run mix test email_test.exs auth_controller_test.exs` | 76 tests, 0 failures | Baseline for the probe |
| Same, **with token-match check removed** | **76 tests, 0 failures** | ⛔ The guarantee is untested |
| `just run mix test email_test.exs` (after restore) | 15 tests, 0 failures | Baseline restored |
| `git diff --stat -- apps/core/lib/stacks/email.ex` | empty | ✅ Probe hygiene clean |
| Census greps (story IDs × files × mapping) | see below | Objective drift evidence |

**Not run:** elm-test, Playwright E2E, any live drive.

## Story census

All 22 stories claimed by the phase table have a story file **and** a `#### US-x.y.z` section in
`implementation-mapping.md`. No gap-direction-2 or -3 findings among the claimed set.

But sections 14–19 contain **24** story files, and only **22** are cited anywhere in the mapping:

| Story file | In mapping? | Reality |
|---|---|---|
| `US-14.4.1-password-reset.md` | ❌ **absent entirely** | Largely **built** |
| `US-14.4.2-resend-confirmation.md` | ❌ **absent entirely** | **Not built at all** |

## Gaps

| # | Direction | Finding | Evidence | Cost if left | Genuine? |
|---|---|---|---|---|---|
| 1 | **6 — built but not guaranteed** | Password-reset **single-use/supersession has no test**. `Email.reset_password/2` looks the user up by `id` *and* `password_reset_token`; that DB-token match is the only thing making a token single-use, since `do_reset_password` nils the token. Remove the match and a **consumed reset token keeps working for its full 24h window**, and a superseded token still works after a newer one is issued. | Probe: `apps/core/lib/stacks/email.ex:93` → `Repo.get_by(User, id: user_id)`; 76 tests still passed. `do_reset_password` nils token at `email.ex:156`. | Security. Token replay on the account-recovery path — the exact flow that exists to protect locked-out users. | ⛔ **Genuine** |
| 2 | **2 — story with no mapping** | `US-14.4.1` and `US-14.4.2` appear **nowhere** in `implementation-mapping.md` — not the phase row, not §14, not the table-to-story or Oban-job inventories. Both are invisible to every gate that reads the mapping. | `grep -oE 'US-1[456789]\.[0-9]+\.[0-9]+'` → 22 IDs; 24 files exist | Account recovery is unscheduled and unestimated. `notes/` calls it Milestone D. | 🟧 Genuine |
| 3 | **4 — plan with no code** | **`US-14.4.2` resend-confirmation is entirely unbuilt.** No route, no controller action, no Elm page, no test. Every `grep resend` hit is the *email provider's* name (`onboarding@resend.dev`). The register→confirm flow dead-ends when the 48h token expires. | `grep -rn resend apps/core/lib apps/core/test frontend/src e2e/tests` → only provider-name matches | A user who loses the confirmation email is permanently locked out. | 🟧 Genuine |
| 4 | **3 + 5 — mapping/code divergence** | The mapping (line 1857) documents settings as `Page.Settings.{Profile, Password, Consent, AgeVerification, Export, Delete, AuditLog, Notifications}`. On disk: `{Profile, Password, Consent, Privacy, AuditLog, Notifications}`. **`Export` and `Delete` don't exist** — they were consolidated into an undocumented **`Privacy.elm`** (which holds `UserClicksExport`, `UserClicksDeleteAccount`, `deleteConfirmationPhrase`). The mapping describes a structure that was refactored away. | `frontend/src/Page/Settings/` vs `implementation-mapping.md:1857`; `Privacy.elm:26–77` | Anyone planning GDPR work from the mapping targets two pages that don't exist. This is the #119 failure class in miniature. | 🟧 Genuine |
| 5 | **stale issue** | Issue **#191** (open, 9 unchecked DoDs) says password reset has "no frontend, and the reset email links to a route that doesn't exist". **Both claims are now false.** `Page/ResetPassword.elm` is wired through `Main.elm:68,210,835` and `Navigation/Route.elm:105`; the email builds `/reset-password/#{token}` (`email_delivery_job.ex:113`) which matches the parser `s "reset-password" </> string`. #191's remaining *real* scope is resend-confirmation (gap 3) + the missing test (gap 1). | as cited | The issue overstates the work, and its stale framing hides the one genuinely missing piece. | 🟧 Genuine |
| 6 | **1 — intent vs plan** | `notes/phase-1-launch-extension.md:31` lists "account recovery (#191)" under **known user-facing gaps** and Milestone D (line 83) treats it as unbuilt. Reality is in between: reset is built-but-untested, resend is absent. The note is directionally right but imprecise, and the mapping is silent. | notes lines 31, 83 | Launch planning is working from a wrong picture in both directions. | 🟨 Genuine |

## What's right (protect these)

- **The confirmation-link design.** `EmailVerificationController.confirm/2` redirects to
  `/confirm-email/success|error` frontend routes rather than returning JSON to a browser — and both
  routes exist in `Navigation/Route.elm:103–104`. Someone thought about the human clicking the link.
- **`password-reset.spec.ts` is a genuinely good E2E spec.** It drives the real journey (forgot form
  → real email → extracted link → new password → sign in), asserts the no-enumeration generic
  response, and uses `mintOrSkip` to skip cleanly rather than fail when the helper is off.
- **No vacuous count-guards in this phase's E2E specs** (`auth`, `login`, `navigation`, `settings`,
  `looking-for-home`, `password-reset`, `private-session`) — notable given the ~16 known elsewhere.
- **The forgot-password-as-login-card-mode decision** (`Main.elm:829–836`) is deliberate and
  documented in a comment explaining *why* deep-linking still works. Good "why" comment.

## One nearly-false finding, recorded as a caution

I initially flagged **US-15.3.1 (footer)** as possibly unbuilt — `Components/Footer.elm` doesn't
exist and a search for `<footer` found nothing. Both were artefacts of my search, not the code: the
footer is rendered inline at `Main.elm:3051` as `footer [ class "app-footer" ]`, exactly as the story
describes ("rendered globally in `view` after `viewPage`"). Similarly, an early grep for a
`stacks_web/router.ex` "found" nothing because **the file doesn't exist** — the real router is
`CoreWeb.Router` (`apps/core/lib/core_web/router.ex`, mounted at `endpoint.ex:62`), which contains
`scope "/api", StacksWeb do` blocks. A silent-failure grep nearly became two phantom findings.

## Deliberate exclusions (do not re-raise)

| Thing absent | Where it's refused |
|---|---|
| `Page.Settings.AgeVerification` / an age-gate Verify affordance | ADR-020 §2 removed it; provider flow tracked in #069. The mapping line 1857 still lists it — that reference is the stale part, not the code. |

## Recommended actions (awaiting your ruling — nothing created yet)

| # | Action | Type | Priority |
|---|---|---|---|
| 1 | Add tests for reset-token single-use + supersession (consumed token rejected; superseded token rejected). Fold into #191's DoD. | issue / test | **⛔ first** |
| 2 | Build resend-confirmation (US-14.4.2): one endpoint + Login-card affordance + rate limit. Already scoped in #191. | issue | 🟧 |
| 3 | Map `US-14.4.1` and `US-14.4.2` into `implementation-mapping.md` — phase row, §14 story-by-story, Oban-job inventory. | mapping fix | 🟧 |
| 4 | Correct mapping line 1857's settings sub-page list to reality (`Privacy` in; `Export`, `Delete`, `AgeVerification` out). | mapping fix | 🟧 |
| 5 | Rewrite #191's Summary — its "no frontend / broken link" claims are false and hide the real remaining scope. | issue edit | 🟧 |
| 6 | Add the missing old-password assertion to `password-reset.spec.ts` step 4 (its comment claims "the old one no longer does"; the test never checks it). | test | 🟨 |
| 7 | **Re-run this audit with the drive**, to convert 22 PARTIAL verdicts into real ones. | audit | 🟧 |
