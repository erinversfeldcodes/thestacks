# Issue #371: Three admin specs share one MFA factor, so they can only pass one at a time

> **Campaign assignment:** Wave 11 (launch gates) — `plans/staff-campaign-2026-07-30.md`. Tracked in the campaign state; completed as part of epic #321.


## Summary
Found by the lead's Wave 6 live drive, 2026-08-01. Three specs in `admin-session.spec.ts` fail
under the default worker count and **all pass with `--workers=1`**:

| Spec | 4 workers | 1 worker |
|---|---|---|
| `signing in through the gate loads the real page with rows` (:142) | ✘ | ✓ |
| `a pending source offers Approve and Reject` (:155) | ✘ | ✓ |
| `an admin ACTION succeeds, not merely the page load` (:167) | ✘ | ✓ |
| `an owner cannot reach an admin page without an admin session` (:129) | ✓ | ✓ |

The one that passes in both is the only one that does **not** call `enrolOwnerMfa`.

## Root cause
`enrolOwnerMfa` (`admin-session.spec.ts:67`) enrols a TOTP factor on the shared `DEV_EMAIL` owner
account and returns its secret. Its own docstring says:

> Re-enrolling is idempotent from the client's side: **it replaces the stored factor.**

That is true for one client and false for four. Run in parallel, spec A enrols secret S₁, spec B
enrols S₂ and *replaces* it, and A's `totp(S₁)` is then rejected — which surfaces as the gate never
opening (`admin-gate` still visible) and, downstream, as `source-approve` never rendering. The
failure looks like a broken admin gate. It is two tests standing on each other.

⚠️ **The symptom is indistinguishable from the four real bugs this spec was written to catch**
(#303's stacked defects: the 401'ing page, the `"pending"` vs `"pending_review"` literal, the
half-wired `initPage`). That is what makes this worth fixing rather than tolerating — a spec whose
false failure mimics its true failure trains people to disbelieve it.

## User Stories
None — test-suite correctness. Protects the #303 regression net.

## Scope Check
One spec file. Single concern.

## Technical Requirements
1. **Give each spec its own account, or serialise the describe.** The project already has the tool
   for the first: `POST /api/test/session` (`mintSession`/`mintOrSkip`, gated by
   `STACKS_E2E_TEST_HELPERS`) mints an isolated confirmed user, and `settings.spec.ts` uses exactly
   that pattern for its own shared-account hazard — read the comment at `settings.spec.ts:330`,
   which reasons about the identical problem and solves it. ⚠️ Prefer isolation over
   `describe.configure({ mode: 'serial' })`: serialising hides the hazard rather than removing it,
   and the next spec added to the file re-acquires it.
   - ⚠️ If a minted user cannot be made platform-owner (admin routes require the role), say so and
     serialise instead — with a comment naming *why*, so it is not silently loosened later.
2. **Assert the isolation holds.** A comment is not a guard. If enrolment stays shared, something
   must fail loudly when a second enrolment lands mid-test rather than surfacing as a stuck gate.
3. **Prove it with the counterfactual.** Run the file at `--workers=4` before and after; quote both.
   ⚠️ A single green run at `--workers=1` is not evidence — that is the state that already passes.

## Reviewer Context
- ⚠️ **`settings.spec.ts:330` is the exemplar**, and it is well done: it documents the hazard, splits
  the dangerous case into its own `test.use({ storageState: … })` describe, and mints a throwaway
  user so a successful password change revokes only that user's session. Copy that shape.
- ⚠️ Do not "fix" this by removing the MFA enrolment and injecting an admin session token directly.
  The whole value of this spec is that it goes through the **real** gate — #303 shipped four admin
  surfaces that passed their own tests by feeding tokens into mocks.
- `workers` is 4 locally and 2 in CI (`playwright.config.ts:21`), so CI is exposed too.
- Related: **#369** (the OOM that made this run hard to read in the first place).
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| E2E | yes | ❌ all four specs pass at `--workers=4` — evidence: the run |
| E2E | yes | ❌ the real gate is still traversed (no injected admin token) — evidence: diff |
| Regression | yes | ❌ counterfactual before/after transcripts quoted |
| Others | no | n/a |

## Definition of Done
- [x] Each enrolling spec isolated (or serialised with a stated reason) — evidence: diff — no spec
      enrols at all now; the single mutation moved to `auth.setup.ts`, so the specs stay parallel
- [x] Passes at `--workers=4` — evidence: 3 acceptance runs + 1 full-suite run, all green
- [x] Still traverses the real MFA gate — evidence: diff — `passTheGate` is unchanged in its UI path
      (fills `admin-email`/`admin-password`/`admin-code`, clicks `admin-verify`); no injected token
- [x] Before/after counterfactual quoted — evidence: both transcripts, in Progress Notes
- [ ] `staff-review` verdict recorded below

## Dependencies
Surfaced by the Wave 6 live drive. Independent of Wave 6's changes — the file was added
2026-07-29 on Wave 0 (`269fe737`). No blocker.

## Agent Assignment
qa / e2e.

## Progress Notes
Filed 2026-08-01 by the lead. The parallel/serial contrast is from two runs against the same
preview at the same commit: `--project=chromium` (3 failures) and `--workers=1` over the same file
(0 failures). The `enrolOwnerMfa` docstring's own "replaces the stored factor" is the mechanism.

**Fixed 2026-08-03 (qa/e2e).** Isolation was preferred and achieved, but not by minting a user: the
admin routes need `role: "owner"` (`:require_owner` on `/api/admin/auth/mfa/*`, and
`AdminAuthController.login` re-checks it), and `POST /api/test/session` mints an ordinary user with
no way to grant that. Minting *owners* on a flag-on public preview would be a privilege escalation,
not a test helper. So the isolation is of the **mutation**, not the account: `enrolOwnerMfa` moved to
`auth.setup.ts` as a third setup step, which every project depends on, and the specs now only READ
the secret via `readOwnerMfaSecret()`. The factor is immutable for the whole parallel phase, so all
four specs stay fully parallel and the file can no longer race itself. Safe because
`Stacks.MFA.verify_totp/2` is a bare `NimbleTOTP.valid?` with no replay protection — parallel specs
presenting the same code in the same 30 s step is fine; only *replacing* the factor was not.

Counterfactual, both at the shipped worker count against `stacks-core-pr-feat-campaign-w7-317`:

- **Before** — `--project=chromium tests/admin-session.spec.ts tests/book-detail.spec.ts`:
  `3 failed / 29 passed (1.2m)`; :142 `expect(admin-gate).toBeHidden() … Received: visible`, :155 and
  :167 `getByTestId('source-approve').first() … element(s) not found`, each burning 19 s.
- **After** — same command, 3 consecutive runs: `33 passed (54.9s)`, `33 passed (1.4m)`,
  `33 passed (56.1s)`. Plus a full-suite `--project=chromium`: the 3 admin specs green.

The isolation guard was probed, not just asserted: re-adding a competing `enrolOwnerMfa(request)`
inside :142 makes it fail in **4.7 s** with
`Received: "That code was not accepted. Codes expire every 30 seconds — try the current one."` and the
`gateAdvances` message naming #371 — instead of the old 19 s ambiguous "gate still visible". Probe
reverted with Edit; `grep -rn PROBE e2e/tests/` clean.

## Related observation (2026-08-05, Wave 8 coherence sweep)
While re-running the E2E against the 1024MB coherence-sweep preview, the setup step **`enrol the
owner's admin MFA factor` intermittently returns 422** at `helpers.ts:588` (`mfa confirm — a 422
here usually means the secret encoding regressed, not a bad code`). It **passed** on one 1024MB run
and **failed** on another with identical code — so it is intermittent, not a hard regression, and
Wave 8 touched nothing in the MFA/TOTP/secret-encoding path. It only blocks the admin-MFA-gated
specs (`admin-session.spec.ts`, `audit-log.spec.ts`); the eight Wave 8 nav/settings/home specs run
on valid auth regardless. Recorded here as the closest home (MFA-factor reliability); may be the
same secret-encoding class this issue and the known preview-MFA concern describe. For the auth owner
to investigate — NOT a Wave 8 defect.
