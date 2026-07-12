---
name: verify-and-followup
description: Run the project's verification gate for changed code, report pass/fail with concrete evidence, and turn any residual gaps or scope-exceeding findings into tracked follow-up issues. Use after finishing a change, before declaring work done, or when the user asks to "verify", "run the gates", "close out", or "check this is complete".
---

# verify-and-followup

The Stacks "confirm → execute → verify → plan the next step" loop. Verification is not "tests pass" — it is evidence plus a tracked home for anything left open.

## Steps

1. **Pick the right gate for what changed** (don't over- or under-run):
   - Elixir / proto / dbt → `just verify` (format, credo, sobelow, **dialyzer**, tests, proto sync, dbt). Long-running → `run_in_background: true`, poll the log.
   - Elm only → `bash scripts/test-elm.sh` + `bash scripts/lint-elm.sh`.
   - A single suite → the targeted `mix test <file>` / `npx elm-test <file>` first, then the full gate before declaring done.
   - Deployed behaviour (uploads, auth, multi-step flows) → the E2E gate (`scripts/deploy-preview.sh` deploys; `scripts/test-e2e.sh` runs Playwright — **deploy-preview.sh does not run the specs itself**).
   - Load `.env` first for anything needing secrets: `set -a; source .env; set +a`.

2. **Report with evidence, never assertion.** Cite the number and the gate: `2259 tests, 0 failures`, `dialyzer done (passed)`, `dbt 207/207`. If something failed, quote the failing output and classify it — real regression vs. environmental flake vs. stale tooling (e.g. a stale dialyzer PLT: rebuild at the umbrella **root**, `mix dialyzer --plt` in a child is a no-op). **Never dismiss a flake as "not ours"** — reproduce or explain it.

3. **Close the loop on residuals.** For every gap, weakened test, or finding that exceeds the current change's scope:
   - If it's in-scope and small → fix it now and re-run the gate.
   - If it exceeds scope (scope-lock) → **create a follow-up issue** from `issues/TEMPLATE.md` (prefer `mcp__project-tools__create_issue`), with reproduction/root-cause, a proposed fix, and — if it's a test-coverage gap — an embedded audit + a "audit is GREEN" DoD item (see the `test-audit` skill). Note the new issue number back to the user.

4. **Final summary** (short): each gate → pass/fail with its number; the list of follow-up issues created; and a one-line "done / not done" verdict. Write any long report to a file and summarise, per the deliverable convention in `docs/agents/standards/code-quality.md`.

## Notes
- This is the lightweight loop for a single change. For multi-phase work, the orchestrator protocol (`docs/agents/orchestrator-agent.md`) owns the full gate sequence — use that instead of this skill.
- Scope-lock: new discoveries become new issues, not silent scope creep on the current one.
