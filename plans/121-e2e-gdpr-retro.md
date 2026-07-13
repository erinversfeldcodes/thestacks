# Retrospective: E2E/GDPR v1 test-hardening + telemetry (epic root)
**Issue**: #121
**Date**: 2026-07-13
**Phases completed**: 7
**Agents involved**: elixir-agent, testing-agent, elixir-reviewer, testing-coordinator, principle-engineer

---

## What Worked Well

- **The Feature-Completeness Pre-Check caught the issue-outruns-implementation gap before any test was written.** It forced Approach A (de-scope v2 into #183–#189) instead of letting a green audit hide unbuilt features — exactly the #124/US-14.3.2 failure mode the check exists to prevent.
- **Phases 1–3 (test-only) landed with 0–1 revision cycles.** Tight, single-concern scopes (erasure invariants; job config; storage assertions) meant the reviewer had little to push on.
- **The 2F Principal Engineer gate earned its keep.** Every per-phase reviewer APPROVED, `just verify` was green, and the audit read GREEN — yet the PE found a real P0 (user PII surviving in `event_log`) that all six phase reviewers missed because it was a *system-level* contradiction between an emitter and an erasure path, not a within-phase defect.
- **Independent orchestrator re-runs of every gate caught two agent self-report errors** — Phase 4's PromEx tag-drop (deletion success series dropped) surfaced via the security-lens reviewer, and Phase 7's "0 failures" self-report was actually a 1-failure flake caught by re-running regression myself.
- **The pinned-toolchain wrapper (`just run`) held** across ~10 background test/deploy runs with no `_build` corruption.

---

## What Caused Friction

- **A per-phase reviewer cemented a false security invariant (root cause of the P0).** Phase 1's reviewer strengthened the event_log test to a byte-identity snapshot — but the *premise* ("payloads carry no PII") was never checked against the actual emitters. The reviewer optimised the test without auditing the claim it encoded. Root cause: the phase scope was "assert event_log unchanged," so no one grepped emit sites for PII until the PE did.
- **Agent self-reports overstated green twice** (Ph4 metrics tag-drop invisible to firing tests; Ph7 "2230/0" was actually 2230/1). Root cause: firing tests bypass the PromEx reporter; and the agent ran a narrower suite than the full regression. Both were caught only because the orchestrator re-verifies rather than trusting.
- **A pre-existing global-Logger-level flake (ISBNResolver) only surfaced under full-suite concurrency**, costing a diagnosis cycle mid-P0-fix. Root cause: `async: true` on a module that mutates global logger state.

---

## What Should Change in the Agent System

| File | Change | Addresses friction point |
|------|--------|--------------------------|
| `docs/agents/reviewers/elixir-reviewer.md` | Add a review check: "When a test asserts an invariant (e.g. 'no PII', 'append-only', 'never modified'), verify the *premise* by grepping the producers (emit sites, writers), not just that the assertion passes. A green test on a false premise is a defect." | Phase-1 false-invariant P0 |
| `docs/agents/standards/testing-standards.md` | Add: "Telemetry/metrics firing tests MUST also assert the metric is *recorded by the reporter* (tag-set validation), not only that the `:telemetry` event fires — a handler-level assert bypasses PromEx tag validation." | Phase-4 PromEx tag-drop |
| `docs/agents/elixir-agent.md` | Add to the completion-report contract: "Regression counts MUST come from the full suite named in the plan's Test Command, not a subset. State the exact command run." | Ph7 narrow-suite self-report |
| `docs/agents/standards/testing-standards.md` | Add: "A test that mutates process-global state (Logger level, application env, global config) MUST be `async: false`." | ISBNResolver flake |
| `docs/agents/orchestrator-agent.md` | Codify an **Epic Parallel Execution** mode (integration branch, worktree-per-issue, dependency DAG, single-PR-at-end) — see the #121 follow-up protocol change. | Enabling the requested epic workflow |

---

## Suggested Issues

- [ ] **Cross-aggregate event_log residue on erasure** — events *about* an erased user under other aggregates (`social.user_blocked` blocked_id, `blog.*` user_id + free-text `title`, marketplace seller_id) keep UUIDs/titles. Fold into **#185** (deeper deletion cascade). (PE non-blocking note.)
- [ ] **Consent `:feature` telemetry label whitelist** — when #184 wires the user-supplied consent `type`, whitelist it before it becomes a Prometheus label (cardinality). Note in **#184** reviewer context. (PE P3.)
- [ ] **Orchestrator protocol: Epic Parallel Execution mode** — codify the integration-branch + worktree + DAG + single-PR workflow. (In progress as the next step.)
