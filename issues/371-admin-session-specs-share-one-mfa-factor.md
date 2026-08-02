# Issue #371: Three admin specs share one MFA factor, so they can only pass one at a time

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
- [ ] Each enrolling spec isolated (or serialised with a stated reason) — evidence: diff
- [ ] Passes at `--workers=4` — evidence: the run
- [ ] Still traverses the real MFA gate — evidence: diff
- [ ] Before/after counterfactual quoted — evidence: both transcripts
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
