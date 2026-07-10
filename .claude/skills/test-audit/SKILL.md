---
name: test-audit
description: Build or regenerate the embedded 13-layer test-coverage audit for an issue — verifying every cell against the real test suites, producing a punch list of gaps, embedding it in the issue, and adding a "audit is GREEN" DoD item. Use when asked to "audit test coverage", "map what's tested", generate a coverage baseline for an issue, or re-baseline an audit after implementation.
---

# test-audit

Encodes The Stacks embedded-audit workflow (proven across issues #112–#127 and the #124 re-baseline). The audit starts as a pre-implementation **baseline** (the work queue) and becomes the exit criterion — the issue is Done when its audit is green.

## Template & inputs
- Read `plans/test-audit-plan.md` FIRST — it is the canonical format (framework-layer summary, coverage tally, full 13-layer × user-story tables with happy/sad columns, numbered punch list, verdict) and a fully-worked example.
- Read the target issue for its user stories and per-layer requirements (the assertion inventory).

## The 13 layers (× each user story, happy + sad columns)
API calls · auth & middleware guards · database interactions · event flow & lifecycle · background jobs (Oban) · external service calls · storage · cache · dbt models · Elm frontend state machine · operational metrics · performance & usability · cost tracking.

## Rules (non-negotiable)
1. **Classify every cell** `✅` (real coverage) / `⚠️` (shallow) / `❌` (missing) / `n/a` (one-line rationale). Every `n/a` carries a reason (covered at a higher level like the SLO gate, genuinely N/A, or a deliberate design decision).
2. **Never invent a test name.** Every `✅` cites a test file + description string you verified by grep/Read of the actual suites: `apps/core/test/**`, `frontend/tests/**`, `e2e/tests/*.spec.ts`, `dbt/**/schema.yml` + `dbt/tests/**`, `apps/vision/tests/**`, `apps/scraper/` cargo tests.
3. **Distinguish "test missing, feature exists" from "feature not implemented"** — check `apps/core/lib` / `frontend/src` before deciding; the latter becomes a spin-out feature issue, not a test punch item.
4. **Layers 11/12 are usually `n/a — covered by SLO gate`** (`scripts/check-slo-gate.sh`); telemetry *firing* tests count where they exist.
5. Write the audit incrementally to a file/section as you verify — don't hold the whole thing in memory for one final write (it can be lost mid-run).
6. **Every applicable cell names a validation path, not just a status.** A `✅`/`❌` is backed by *how* the behaviour is (or will be) proven — the right layer per the `write-validation-test` skill. Crucially: when browser/Playwright E2E is the wrong tool (backend-only behaviour, a security invariant, a harness/CI change), that cell is **not** `n/a` — it demands an acceptance or live-stack test that reaches the state the way a real user would. `n/a` means genuinely-not-applicable or covered-at-a-higher-level, never "hard to E2E". A behaviour with no validation path is a `❌` punch item.

## Output
- Produce the framework summary, coverage tally, full per-layer tables, and a **numbered punch list** (every ❌/⚠️: id, cell, test needed, which suite/file).
- **Embed it in the issue** under a `## Test Audit` section (demote the audit's headings one level so they nest), and add a DoD item: *"Test audit (embedded above) is GREEN — every cell ✅ or n/a-with-rationale; 0 ❌, 0 ⚠️; regenerate as the final step."*
- Return a concise summary (verdict counts + punch-list size + 2–3 key gaps), not the whole audit.

## Baseline vs. re-baseline
- **Baseline** (pre-implementation): most ❌ are expected — they are the work queue. Header: "baseline, pre-implementation".
- **Re-baseline** (post-implementation): re-verify every cell against the *shipped* suites — this is discovery, not a rubber-stamp. It is green only when every cell is `✅` or `n/a`; force nothing. Fold in what the work taught you (bugs found, stale issue prose, deferred cells → `n/a (see #NNN)`).

## Scale
- Many issues → fan out one agent per issue (they're independent), each writing its own `plans/<slug>-test-audit.md` or embedding directly. Spot-check citations afterward (grep a sample of cited test strings to confirm they exist).

## Related skills
- `create-issue` embeds a **baseline** audit at ticket-creation time — this skill is its step 4.
- `write-validation-test` is how a `❌` cell becomes `✅`: it picks the right layer and keeps
  live-stack tests honest (realistic user behaviour, no artificial pokes).
- `verify-and-followup` turns residual `❌`/`⚠️` cells that exceed scope into tracked follow-up issues.
