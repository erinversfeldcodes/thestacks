# Issue #363: Success states are committed states, and five duplication families collapse to one source each

## Summary
Wave 6 item 6e of epic #316 — the last child. Two success states currently make a correct decision and
then fail to commit it (the forgot-password acknowledgement is announced to nobody; a completed password
reset can be un-told by a keystroke), and five "correct decision, hand-copied N times, no gate" families
collapse to a single source each.

## User Stories
US-14.4.1 (reset acknowledgement), US-17.2.x (settings forms), US-16.3.1 (visibility affordances).

## Goal
A reader who is told something worked is told it once, out loud, and cannot be un-told it. Each of the
five duplicated decisions has exactly one place it is written down, and the collapse is done by
**measurement** — every family's site count established by grep before anything is deleted, and every
site checked for being genuinely the same decision rather than merely a similar shape.

## Scope Check
- Controllers touched: 1 (`AuthController`, a private helper only) → OK
- New endpoints: 0 → OK
- Production LOC: ~290 (Elm ~230, Elixir ~60, CSS ~25) → at the limit, not over
- Unrelated concerns? No — every item is "a decision that exists in more than one place, or a decision
  that is made and then dropped". The Elixir leg (`Duration`) is one of the five families, not a
  separate concern.

## Wiring
Router wiring: includes wiring, user-facing on completion. `Page.ResetPassword` gains an `OutMsg` that
`Main` turns into a navigation (auto-advance to `/login`); everything else is view/behaviour changes on
already-routed pages.

## Feature-Completeness Pre-Check

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-14.4.1 forgot-password ack | `Login.elm:519` renders the ack as `p.login-card__subtitle` — no `role="status"`, so a screen reader is never told the mail was sent | ack renders, is not announced | 🟡 partial | built in-scope (adopt the `notice` component already on the card) |
| US-14.4.1 reset completes | `ResetPassword.elm:78-84` `Completed` sets `Success ()`; `:61,:64` reset `submitting = NotAsked` on every keystroke; nothing stops a second submit | success reachable, and destroyable | 🟡 partial | built in-scope (terminal success + auto-advance) |
| US-17.2.x settings forms save | `Profile.elm:353`, `Privacy.elm:740`, `Consent.elm:193`, `Password.elm:185` each render their own save button; the `Success` branch has no `onClick` | button reachable, inert after a save | 🟡 partial | built in-scope (one component, `Success` stays live) |
| US-16.3.1 a hidden book reads as hidden | `Spine.elm:317-320` — `opacity: 0.35` inline + an aria-label suffix; no visible marker | hidden book renders faded, unlabelled to a sighted reader | 🟡 partial | built in-scope (visible affordance + contrast fix) |

Verdict: ✅ implemented · 🟡 partial · ❌ missing. All four are 🟡 and all four are built in-scope.

## Technical Requirements

### A. Success states
1. **Forgot-password acknowledgement** (`Page.Login.viewForgotForm`) uses the card's existing `notice`
   helper (`Login.elm:860`, which stamps `role="status"`) instead of a bare `p`. The class literal stays
   spelled at the call site — folding it into the helper hides it from `check-orphan-classes.sh` (#356).
2. **Reset-password success is terminal** (`Page.ResetPassword`): `SetPassword` / `SetConfirmPassword`
   must not be able to leave `Success`, and a `Completed` arriving after a success must not overwrite it.
   After success the page **auto-advances** to `/login` via a new `OutMsg`, consumed by `Main`.

### B. The five families — measure, then collapse
1. `Components.SaveButton` — promoted from `Profile.viewSaveButton`, **with the dead `Success` branch
   fixed** (it renders an enabled-looking, focusable, keyboard-activatable button with no `onClick`).
2. `Types.Password` — one source for the length rule and the sentence the reader is shown.
3. `Types.Placement.visibility : Maybe Visibility` — parsed at the decode boundary; `== Just "owner"`
   becomes `Types.Placement.isHidden`. Plus a **visible** hidden affordance on the spine.
4. `Stacks.Duration.to_seconds/1` — one `{n, unit}` → seconds conversion for the three Elixir copies.
5. Whatever the epic's requirement 5 lists that 1–4 do not cover — reported, not silently dropped.

## Reviewer Context
- **`check-orphan-classes.sh` budget is 0.** Every new `class "…"` literal in Elm needs a real rule in
  `frontend/css/main.css`, unless it is a verified test hook. The gate cannot see `class (if … then …)`
  forms at all (#356), so a computed class is unprotected either way.
- **`check-css.sh` cannot see a base rule placed *after* its own modifier at equal specificity (#365).**
  `.login-card__notice` (line 5956) sits after `--session-expired` (2662) and `--account-deleted` (2680)
  and silently wins every property they share. Any new notice styling must go **after** the base rule or
  be dead on arrival. Verified by `getComputedStyle`, not by the gate.
- `Spine.book` sets `opacity` as an **inline style**, which beats any stylesheet rule. Moving the hidden
  treatment into CSS requires removing the inline declaration first.
- Four sibling guarantees land on this branch and must survive: `check-session-expiry-coverage.sh` (#361),
  `check-http-timeouts.sh` (#362), `PersistFirstLoginTest` + its probe (#359), and
  `TestHelpers.libraryEffects` **calling** `Bookshelf.mutationToken` (#332).
- `Main.Model` embeds an unconstructable `Nav.Key`, so a wire into `Main` is tested through a key-free
  exposed function that `Main.update` **calls** (the `loginRedirectFor` idiom), never mirrors.

## Test Audit

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm state machine | yes | ✅ `frontend/tests/Page/ResetPasswordTest.elm` — success survives keystrokes, survives a late `Completed`, and emits `AdvanceToLogin`; `frontend/tests/Components/SaveButtonTest.elm` — the `Success` branch is clickable; `frontend/tests/Page/Settings/ConsentTest.elm` "toggling analytics after a save returns the button to its saveable state" |
| Auth & guards | yes | ✅ `scripts/check-session-expiry-coverage.sh` → exit 0 re-verified after the sweep (24 pages, 68 endpoints) |
| API | yes | ✅ `scripts/check-http-timeouts.sh` → exit 0 re-verified (91 requests bounded) |
| Elm decode boundary | yes | ✅ `frontend/tests/PlacementDecoder.elm` — `visibility` decodes to `Visibility`, unknown wire values decode to `Nothing` |
| Elixir unit | yes | ✅ `apps/core/test/stacks/duration_test.exs` — every unit, and the unknown-unit fail-safe |
| Elixir integration | yes | ✅ `apps/core/test/stacks/accounts/guardian_test.exs` (rotation grace), `apps/core/test/stacks/workers/guardian_token_sweep_job_test.exs` (absolute cap) still green through the extraction |
| Prose/copy | yes | ✅ `frontend/tests/PasswordRuleTest.elm` — every reader-facing statement of the rule comes from `Types.Password`, paired with a positive control (`check-prose-assertions.sh` cannot see `ensureViewHasNot`) |
| Visual/contrast | yes | ✅ `getComputedStyle` on a running page, captured in Progress Notes — the affordance is measured, not asserted |
| E2E | yes | ✅ existing `e2e/tests/settings.spec.ts:740` and `e2e/tests/register.spec.ts:180` pin two of the reader-facing rule statements; unchanged wording keeps them green |
| DB / events / Oban / storage / cache / dbt / external | no | n/a — no schema, no event, no job, no model changed |
| Metrics / performance / cost | no | n/a — covered by the SLO gate |

Punch list (all closed at completion — see Progress Notes):
1. Reset success destroyed by a keystroke → `ResetPasswordTest` terminal-success tests.
2. Save `Success` branch inert → `SaveButtonTest`.
3. Consent analytics unsaveable after one save → `ConsentTest`.
4. Four wordings of one rule → `PasswordRuleTest`.
5. `== Just "owner"` ×3 → `PlacementDecoder` + `BookcaseHelpersTest`.
6. `{n, unit}` ×3 with divergent unit tables → `duration_test.exs`.

Verdict: baseline ❌ ×6 → GREEN.

## Definition of Done
- [x] Forgot-password acknowledgement carries `role="status"` — evidence: `frontend/tests/Page/ForgotPasswordNoticeTest.elm` (4 tests); computed style on a running page 2026-08-01 → `{tag: DIV, role: "status", cls: "login-card__notice", color: rgb(74,124,89), background: rgba(74,124,89,0.15), borderLeft: 2px solid rgb(74,124,89)}` vs the helper text beside it `{tag: P, role: null, cls: "login-card__subtitle", color: rgb(107,90,69), background: transparent}`
- [x] Reset success cannot be destroyed by input or by a late response, and auto-advances — evidence: `frontend/tests/Page/ResetPasswordTest.elm` (23 tests); probe `clearStaleError _ = NotAsked` → 4 fail; wire asserted at the only reachable layer, `e2e/tests/password-reset.spec.ts` step 4
- [x] One `Components.SaveButton`, `Success` branch live — evidence: `frontend/tests/Components/SaveButtonTest.elm` (13 tests); probe dropping `onClick` from `Success` → 2 fail; measured 6 implementations / 7 call sites collapsed
- [x] One password-rule source — evidence: `frontend/tests/PasswordRuleTest.elm` (14 tests); measured 10 Elm sites in 5 wordings → 1 source
- [x] `Visibility` at the decode boundary; hidden affordance visible and contrast-passing — evidence: `getComputedStyle` on a running page 2026-08-01 → hidden-book title contrast **4.71:1**, identical to a visible book, up from **1.80:1** at the old inline `opacity: 0.35`; padlock 11×9.9px, `aria-hidden=true`, absent on a visible book; dashed brass outline present on hidden only
- [x] `Stacks.Duration.to_seconds/1` replaces three copies — evidence: `just run mix test` → `3 doctests, 190 tests, 0 failures`; probe reintroducing a private unit table → `duration_test.exs:110` fails naming the offender
- [x] All four sibling guarantees re-verified — evidence: `check-session-expiry-coverage.sh` exit 0 (24 pages / 68 endpoints); `check-http-timeouts.sh` exit 0 (91 requests); `PersistFirstLoginTest` 15/15; `TestHelpers.libraryEffects` still calls `Bookshelf.mutationToken` (probe → `read_only_synthetic_organiser_msg_SECURITY` fails). Full probe transcripts in Progress Notes.
- [x] Every behaviour has a validation path — evidence: Test Audit above; the one irreducible gap (`Nav.pushUrl` behind an unconstructable `Nav.Key`) is asserted in E2E, not waved
- [x] Tests written and passing — evidence: `npx elm-test` → `1549 passed, 0 failed` (baseline 1483); `just run mix test` on the touched Elixir → `190 tests, 0 failures`
- [x] Standards compliance verified — evidence: `scripts/lint-elm.sh` → "I found no errors!" with all six gates green; `just run mix format --check-formatted` exit 0; `just run mix credo --strict` → `4117 mods/funs, found no issues`
- [x] Test audit GREEN — evidence: every row above cites a real suite verified by running it
- [ ] `completion-audit` passed — for the integrating agent; not run here
- [ ] Meets the Completion Bar — preview drive of the E2E additions outstanding (this worktree has no e2e `node_modules` and cannot run Playwright)

## Dependencies
- #316 (epic). Merges on top of #359, #332, #361, #360, #362 — all five Wave 6 siblings.
- #365 (base-after-modifier CSS collision) is a **known blind spot worked around here**, not fixed here.
- #356 (orphan gate blind to computed classes) likewise.

## Agent Assignment
elm-agent (primary), with an Elixir leg for `Stacks.Duration`.

## Progress Notes

Filed and built 2026-08-01 by the elm-agent (Wave 6 item 6e, the wave's last child).

### The census — measured before anything was collapsed

The epic's numbers are a survey. These are counts.

| Family | Epic said | Measured | Genuinely the same decision | Rejected as merely similar |
|--------|-----------|----------|------------------------------|-----------------------------|
| Save button | ×6 | **6 implementations, 7 call sites** | 6/6 | `Privacy.viewShelfRow`'s per-row "Save" (no `RemoteData` state at all — a plain button per shelf sharing one page-level `savingShelf` that only feeds a paragraph); `Settings.Notifications` has **no** save button (it auto-saves on toggle) |
| Password rule | 9 sites, 4 wordings | **10 Elm sites (3 length checks + 7 statements) in 5 wordings**, plus 4 Elixir `validate_length` messages in 1 wording — 14 total | 10/10 Elm | The 4 Elixir messages: a different system with its own validation vocabulary. Left alone, cross-referenced from the Elm module's doc |
| `Visibility` at the boundary | `== Just "owner"` ×3 | **3**, plus a 4th site of the same decode decision (`BookDetail.elm:385` re-parsing the string at the use site) | 4/4 | **3 of the 6 `"owner"` literals in `src/` are not visibility at all** — `Main.elm:727,3529` are `auth.user.role == "owner"`, the platform-**owner role**, and `Privacy.elm:443` is a form `<option value>` round-tripped to the server. Collapsing on the literal would have been the false collapse |
| `Duration.to_seconds/1` | ×3 | **3** | 3/3 | — |
| "Anything else in requirement 5" | — | Nothing further in req 5; the two success states and families 1–4 cover it | — | Findings outside it listed below |

### The latent bugs the collapses surfaced

**1. `Settings.Consent`: analytics consent could not be revoked without a page reload.**
The save button's `Success` branch had no `onClick` — an enabled, focusable, keyboard-activatable
primary button reading "Saved!" and wired to nothing. Harmless on `Profile` and `Privacy`, because
every edit message there resets `saving` to `NotAsked`. `Consent.ToggleAnalytics` did not, and nothing
else on the page could. So: grant consent → Save → "Saved!" → change your mind → the button still says
"Saved!", is inert, and claims the unsent value is saved. **A consent revocation that silently fails.**
Fixed on both halves: `Components.SaveButton`'s `Success` branch keeps its `onClick`, and
`ToggleAnalytics` clears `saving`. Probe: removing either reddens `SettingsTest`/`SaveButtonTest`.

**2. `Stacks.Accounts` honoured `{1, :day}` as one second.**
`grace_unit_in_seconds/1` handled `:second`/`:minute`/`:hour` and fell through to a fail-safe catch-all
of `1` for everything else — while its comment said it "mirrors the AuthController session-cap
`unit_in_seconds/1`", which handles `:day` and `:week`. A `session_rotation_grace` of `{1, :day}` was
therefore an **86,400× error in a token-rotation security window**, on the one copy whose comment
claimed it matched the others. Two of three promises kept; the third was the one that mattered.

**3. `Page.ResetPassword` could tell a reader it worked and then take it back.**
`SetPassword`/`SetConfirmPassword` set `submitting = NotAsked` unconditionally. Typing while the request
was in flight re-armed the submit button; a second press spent the **single-use** token behind a reset
that had already succeeded. The 200 renders "Your password has been reset"; the 400 for the burned
token then replaces it with "This reset link is invalid or has expired". The reader is left holding the
false message. Now: typing clears a stale `Failure` and nothing else, `Submit` is ignored from `Loading`
or `Success`, and a `Completed` arriving after a success cannot overwrite it.

### The affordance, measured rather than asserted

Verified in Chrome via `getComputedStyle` against the real stylesheet and the real
`Components.Spine.book` output (temporary harness module, built, measured, deleted):

| | before | after |
|---|---|---|
| hidden-book title vs its own spine | **1.80:1** (inline `opacity: 0.35`) | **4.71:1** |
| visible-book title vs its own spine | 4.71:1 | 4.71:1 |
| visible marker for a sighted reader | none | padlock 11×9.9px, `aria-hidden="true"` + dashed brass outline |

The opacity was removed entirely rather than raised. Measured: the palette has almost no headroom —
a *visible* spine title is only 4.71:1 — and every point of transparency composites foreground and
background together toward the backdrop, so 0.88 still gives 4.12:1 and it takes 0.97 to clear 4.5,
by which point the fade communicates nothing. State is carried by a marker, never by making the one
book whose privacy you might want to check the one book you cannot read.

**#365 reproduced live while I was in there.** The session-expired notice, which *declares* amber
`#6b4310` on `rgba(184,134,11,0.12)` at `main.css:2662`, computes to `rgb(74,124,89)` on
`rgba(74,124,89,0.15)` — the base `.login-card__notice` rule at line 5956 wins at equal specificity.
That is why the new acknowledgement carries **no modifier**: an unmodified `.login-card__notice` is the
only notice on that card that renders what it declares. Not fixed here; #365 owns it.

### Probe transcripts

| Probe | Result |
|---|---|
| #361 — `Page/Insights.elm` returns `NoOut` instead of `SessionExpired` (a page the hand-written `SessionExpiryPagesTest` does not name) | `check-session-expiry-coverage.sh` **exit 1**, naming the page — while **all 1549 Elm tests pass**. Reverted by Edit; `git diff` on the file → 0 lines |
| #362 — `Api.elm:518` `timeout = standardTimeout` → `Nothing` | `check-http-timeouts.sh` **exit 1** — while **all 1549 Elm tests pass**. Reverted; `git diff` → 0 lines |
| #359 — `PersistAuth` removed from `Main.loginEffects` | `PersistFirstLoginTest` **4 failures** (11/15). Reverted; 15/15, `PersistAuth` count back to 5 |
| #332 — `TestHelpers.libraryEffects` reads `model.token` instead of calling `Bookshelf.mutationToken` | `read_only_synthetic_organiser_msg_SECURITY` **fails**. Reverted; 21/21 |
| #363 — `SaveButton` `Success` branch loses its `onClick` | `SaveButtonTest` **2 failures** |
| #363 — `Consent.ToggleAnalytics` stops clearing `saving` | `SettingsTest` **2 failures** |
| #363 — `ResetPassword.clearStaleError _ = NotAsked` | `ResetPasswordTest` **4 failures** |
| #363 — `Spine` re-adds the inline `opacity: 0.35` | `SpineHiddenTest` **2 failures** (the assertion is live, not vacuous) |
| #363 — a module outside `Stacks.Duration` defines its own unit table | `duration_test.exs:110` **fails**, naming the offending file |
| ⚠️ #363 — `Main`'s ResetPasswordMsg branch stubbed to `[]` | **1549/1549 still pass, `elm-review` clean.** The wire is not reachable from Elm — `Main.Model` embeds an unconstructable `Nav.Key`. This is the seam the #360/#361 reconcile warned about, and it is why the auto-advance is asserted in `e2e/tests/password-reset.spec.ts` rather than declared covered |

### Suite counts
`npx elm-test` 1483 → **1549**, 0 failures. `just run mix test` on the touched Elixir: **190 tests + 3
doctests, 0 failures**. `scripts/lint-elm.sh`: all six gates green, `elm-review` "I found no errors!".
`mix format --check-formatted` exit 0. `mix credo --strict`: 4117 mods/funs, no issues.

### Out of scope — found, not fixed
1. **`viewFeedback` is the same family, unnamed by the epic.** Five near-identical success/error
   paragraph renderers across `Profile` (×2 shapes), `Privacy`, `Consent`, `Password`, `Notifications`,
   with five different wordings for "could not save". Same shape as the save button; a sibling issue.
2. **`Components.VisibilityBadge` still takes a raw `String`** and cases over `"owner"`/`"group"`/
   `"platform"` itself — a fourth place the enum is spelled. Its only caller,
   `Page.Blog.Archive:98`, converts a typed value **to** a string to feed it.
3. **`Types.Shelf.visibility` is still a `String`** (`Bookshelf.elm:230,252` default it to `"owner"`).
   The placement boundary is typed now; the shelf boundary is not.
4. **`Page.Blog.Editor` has a second `RemoteData` pair** (`saving`/`publishing`) with no reset on edit —
   the same shape as the Consent bug. Not reachable the same way (the editor's `Success` button is now
   clickable), but the "Draft saved!" label can outlive the draft it describes.
5. The E2E additions could not be run from this worktree (no `e2e/node_modules`); they are formatted
   and parse, and need a preview drive.
</content>
</invoke>

**staff-review verdict: LGTM** (2026-08-01, lead, Mode B on 79c6c355). The strongest dedup work of the campaign, and the collapses paid for themselves three times over.
Praise: (a) **it measured every family and reported the count**, as asked — and the numbers moved: the save button was 6 implementations across 7 call sites, the password rule **10 Elm sites in 5 wordings** (not 9 in 4) plus 4 Elixir messages, and `Visibility` had a **fourth** site the epic missed (`BookDetail.elm:385` re-parsing the string at the use site); (b) **it refused the false collapse that was available.** Three of the six `"owner"` string literals are not visibility at all — `Main.elm:727,3529` are `auth.user.role == "owner"` (the platform-owner *role*) and `Privacy.elm:443` is a form `<option value>`. Collapsing on the literal is exactly what a careless sweep does, and it named that as the trap rather than walking into it; (c) it also declined to merge the 4 Elixir `validate_length` messages into the Elm rule — different system, cross-referenced instead.
**Three latent bugs, all surfaced by the collapses, two of them serious — lead-verified against the pre-merge code:**
1. ⛔ **Analytics consent could not be revoked without a page reload.** Confirmed: the save button's `Success` branch rendered `button [ class "btn btn--primary" ] [ text "Saved!" ]` with **no `onClick`** — enabled, focusable, keyboard-activatable, wired to nothing — and `ToggleAnalytics` returned `( { model | analyticsConsent = not … }, Cmd.none, NoOut )` **without resetting `saving`**. So: grant → Save → change your mind → the button still reads "Saved!", is inert, and asserts the unsent value is saved. **A consent revocation that silently fails**, which is a GDPR-relevant defect — withdrawal must be as easy as granting. Harmless on Profile/Privacy only because every edit there resets `saving`; `Consent` was the one page that did not.
2. ⛔ **`Stacks.Accounts` honoured `{1, :day}` as ONE SECOND.** Its private unit table stopped at `:hour`, so a `session_rotation_grace` of `{1, :day}` fell into the catch-all — **an 86,400× error in a token-rotation security window**, on the single copy whose comment claimed it mirrored the AuthController converter. `Stacks.Duration` now carries the fail-safe that made the catch-all defensible (unknown unit → seconds, so a misconfiguration fails toward *less* grace) along with the units that made it wrong.
3. Reset-password could tell a reader it worked and then take it back — typing mid-flight re-armed submit, and a second press spent the single-use token behind an already-successful reset, replacing the confirmation with a 400.
**Contrast fixed by measurement, not by taste:** hidden-book title **1.80:1 → 4.71:1**, identical to a visible book. It **removed** the opacity rather than raising it, with the arithmetic: a *visible* spine title is only 4.71:1, so 0.88 yields 4.12 and it would take 0.97 to clear 4.5 — i.e. the affordance had to stop being opacity. State is now a padlock plus a dashed brass outline. **It independently reproduced #365 live** — the session-expired notice declares amber and computes `rgb(74,124,89)` — which is why its new acknowledgement deliberately carries no modifier.
**All four sibling guarantees re-probed rather than assumed**, each with the same signature: session-expiry gate **exit 1** while 1549 tests pass; timeout gate **exit 1** while 1549 pass; persist-first probe 4 red; the `TestHelpers` → `Bookshelf.mutationToken` link fails when mirrored. It also caught its own slip — one revert over-replaced a line in `Insights.elm`, found by `git diff` and restored byte-identical.
**⚠️ The wire, again.** Stubbing `Main`'s `ResetPasswordMsg` branch to `[]` leaves **1549/1549 passing and elm-review clean**, because `Main.Model` embeds an unconstructable `Nav.Key`. It asserted the auto-advance in `e2e/tests/password-reset.spec.ts` instead and exposed `Main.resetPasswordDestination` key-free so the destination itself is unit-tested — the `loginRedirectFor` idiom. That is the third time this wave a module seam has proven unreachable from elm-test.
Counts: Elm **1483 → 1549 / 0**; Elixir touched suites **190 tests + 3 doctests / 0**; `lint-elm.sh` all six gates green; `mix format` clean; `credo --strict` no issues.
**Findings carried forward:** `viewFeedback` is the same family across 5 settings pages in 5 wordings for "could not save"; `Components.VisibilityBadge` still takes a raw `String` (its only caller converts a typed value *to* one); `Types.Shelf.visibility` is still `String`; `Blog.Editor`'s `saving`/`publishing` never reset on edit. ⚠️ **The new E2E specs were not run** — the worktree has no `e2e/node_modules`; they need the wave's preview drive.
