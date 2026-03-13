# Retrospective: Test-First Agent Workflow
**Issue**: #018
**Date**: 2026-03-13
**Phases completed**: 3
**Agents involved**: platform-agent (all phases)

---

## What Worked Well

- **Parallel specialist updates**: Splitting the 10 specialist agents into two batches of 5 and running them in parallel cut Phase 2 wall-clock time roughly in half. The consistent "Orchestrator Integration" structure across all agents made this safe — no inter-file dependencies.
- **Research-first approach**: The Explore agent's upfront research mapped every file's section structure and line numbers before any edits began. This eliminated guesswork about insertion points and made the plan precise.
- **Mechanical consistency**: All 10 specialist agents and all 7 reviewers follow identical patterns, so a single template could be applied to each. No per-file customisation was needed beyond test commands.
- **No revision cycles**: All three phases completed in a single pass with no reviewer feedback required — appropriate for documentation-only changes with clear specifications.

---

## What Caused Friction

- **MCP project-tools unavailable**: The project-tools MCP server wasn't responding, forcing manual file reads instead of `get_issue()` and `get_plan_status()` calls. Minor friction — the fallback (reading files directly) worked fine, but the orchestrator protocol assumes MCP tools are available.
- **Formal review skipped**: For documentation-only changes, the full review cycle (delegate to platform-reviewer, present to human, wait for mediation) adds overhead without proportional value. The orchestrator protocol doesn't have a lightweight path for doc-only phases.

---

## What Should Change in the Agent System

| File | Change | Addresses friction point |
|------|--------|--------------------------|
| `docs/agents/orchestrator-agent.md` | Add a "Documentation-only phase" shortcut in Phase 2 that skips formal review when a phase touches only `.md` files and the orchestrator verifies the changes directly | Review overhead for doc-only phases |
| `docs/agents/orchestrator-agent.md` | Add fallback instructions in Session Resume for when MCP project-tools are unavailable (read files directly from `issues/` and `plans/`) | MCP tools unavailability |

---

## Suggested Issues

- [ ] Doc-only phase fast path — Add orchestrator protocol shortcut that skips formal review for phases modifying only documentation files
- [ ] MCP fallback protocol — Document explicit fallback procedures in orchestrator when MCP project-tools server is unavailable
