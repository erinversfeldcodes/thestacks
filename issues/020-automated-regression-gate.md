# Issue #020: Automated Regression Gate Before Review

## Summary
After a specialist completes work and before the reviewer is invoked, an automated step runs the full test suite against the specialist's changes. If tests fail, the specialist receives the failure output and fixes before the reviewer ever sees the code. This eliminates revision cycles caused by mechanical failures that should never reach review.

## User Stories
Not directly tied to a user story — internal tooling for the agent-driven development workflow.

## Goal
The reviewer never sees broken tests. The gate is automatic — no orchestrator judgment required. Reviewer capacity is fully freed for design, security, and correctness concerns.

## Technical Requirements

### 20.1 — MCP Tool: `run_test_suite`

Add a tool to `scripts/mcp/project_tools.py`:

```python
run_test_suite(domain: str, worktree_path: str | None = None) -> TestResult
```

Returns:
```json
{
  "domain": "elixir",
  "passed": true,
  "summary": "42 tests, 0 failures",
  "output": "...",
  "command": "mix test"
}
```

Supported domains and their commands:

| Domain | Command | Working directory |
|--------|---------|------------------|
| `elixir` | `mix test` | `apps/core/` |
| `elm` | `npx elm-test` | `frontend/` |
| `rust` | `cargo test` | `apps/scraper/` |
| `python` | `pytest` | `apps/vision/` |

Optional `worktree_path` overrides the default working directory for worktree isolation (Issue #022).

### 20.2 — Orchestrator Gate (Phase 2B Revision)

The orchestrator's Phase 2B (Spec Coverage Gate) gains an automated test gate step before the spec coverage check:

1. After receiving the specialist's completion report, call `run_test_suite` for the relevant domain(s)
2. If the suite passes: proceed to spec coverage gate, then review
3. If the suite fails: return the failure output to the specialist without invoking the reviewer. Instruct the specialist to fix and resubmit. This counts as a revision cycle.

This is an automated, objective gate — the orchestrator does not need to exercise judgment.

### 20.3 — Failure Format

If the gate fails, the orchestrator sends back:

```
REGRESSION GATE FAILED: [domain] test suite
Command: [command]
Output:
[verbatim test output]

Fix the above failures and resubmit your completion report.
This counts as revision cycle N of 2.
```

## Definition of Done

- [ ] `run_test_suite` MCP tool implemented for elixir, elm, rust, python domains
- [ ] Orchestrator Phase 2B updated with automated gate step
- [ ] Failure message format documented and implemented
- [ ] Tool tested: passing suite returns `passed: true`; deliberately broken test returns `passed: false` with output
- [ ] Orchestrator tested: failed gate returns to specialist without invoking reviewer

## Dependencies
- Issue #016 (MCP server) — extends project_tools.py
- Issue #018 (test-first workflow) — combined, these two eliminate most pre-review failures

## Agent Assignment
- **python-agent** for MCP tool implementation
- **platform-agent** for orchestrator-agent.md changes

## Progress Notes
<!-- Updated by agents during execution -->
- 2026-03-13: Issue created from agentic techniques feedback.
