# Issue #017: Structured State Files for Cross-Session Orchestration

## Summary
The orchestrator tracks phase status, revision counts, and last actions by printing them in conversation responses — state that evaporates when the session ends. A machine-readable `plans/{NNN}-state.json` file lets a new session resume exactly where the previous one left off, without relying on the human to reconstruct context.

## User Stories
Not directly tied to a user story — internal tooling for the agent-driven development workflow.

## Goal
Opening a new Claude Code session after a context compaction or break, the orchestrator reads `plans/{NNN}-state.json` and immediately knows: which phase is active, which agents have completed, how many revision cycles have occurred, what the last action was, and what the human's outstanding decisions are. No reconstruction from memory or conversation history required.

## Technical Requirements

### 17.1 — State File Schema

Each active plan has a companion state file at `plans/{NNN}-{slug}-state.json`. The file is created when the orchestrator starts work on an issue and updated at the end of every significant action.

```json
{
  "issue": 14,
  "slug": "agent-system-improvements",
  "created_at": "2026-03-13T10:00:00Z",
  "updated_at": "2026-03-13T14:32:00Z",
  "status": "in_progress",
  "current_phase": "14.2",
  "phases": {
    "14.1": {
      "status": "complete",
      "agent": "orchestrator",
      "completed_at": "2026-03-13T11:15:00Z",
      "revision_cycles": 0,
      "reviewer_verdict": "APPROVED"
    },
    "14.2": {
      "status": "in_progress",
      "agent": "elixir-agent",
      "started_at": "2026-03-13T13:00:00Z",
      "revision_cycles": 1,
      "reviewer_verdict": null,
      "last_action": "elixir-agent submitted completion report; reviewer returned NEEDS_REVISION"
    },
    "14.3": {
      "status": "pending",
      "agent": null
    }
  },
  "human_decisions_pending": [
    "Reviewer flagged N+1 query in Shelving.get_bookshelf_books/2 — accept fix or defer to Issue #018?"
  ],
  "notes": []
}
```

### 17.2 — State Transitions

The orchestrator updates the state file at each of these events:

| Event | State change |
|-------|-------------|
| Plan created | File created, all phases `pending` |
| Phase starts | Phase → `in_progress`, `started_at` set |
| Completion report received | `last_action` updated |
| Reviewer returns verdict | `reviewer_verdict` set |
| Reviewer returns NEEDS_REVISION | `revision_cycles` incremented, `last_action` updated |
| Human approves phase | Phase → `complete`, `completed_at` set |
| Human decision required | Item appended to `human_decisions_pending` |
| Human decision made | Item removed from `human_decisions_pending` |
| All phases complete | Top-level `status` → `complete` |

### 17.3 — Session Resume Protocol

The orchestrator's `docs/agents/orchestrator-agent.md` gains a **Resume** section:

> At the start of any session where work is already in progress, before doing anything else:
> 1. Check `plans/` for any `*-state.json` file with `"status": "in_progress"`
> 2. If found, read it and summarise the current state to the human: active phase, last action, pending human decisions, revision cycle count
> 3. Ask the human: "Continue from here, or start fresh?"
> 4. If continuing: pick up from `current_phase` using the agent and context described in `last_action`

This replaces the current pattern of the human manually reconstructing state from memory or conversation summaries.

### 17.4 — Integration with MCP Server (Issue #016)

If Issue #016 is implemented first, the `get_plan_status` MCP tool reads from the state file rather than parsing the plan markdown. The state file becomes the single source of truth for machine-readable plan status; the plan markdown remains human-readable documentation.

The `update_progress` MCP tool also appends a note to `state.notes[]` in addition to the issue file's Progress Notes section.

### 17.5 — State File Lifecycle

- Created by the orchestrator when a plan is first executed (not when the issue is created)
- Updated by the orchestrator throughout execution
- Archived (not deleted) when the plan completes: renamed to `plans/{NNN}-{slug}-state-complete.json`
- Never modified by specialist agents directly — only the orchestrator writes state

### 17.6 — Gitignore Considerations

State files track transient execution state and should not be committed alongside plan files. Add `plans/*-state.json` to `.gitignore`. Completed state files (`*-state-complete.json`) may optionally be committed as part of the historical record.

## Definition of Done

- [x] State file schema documented in `docs/agents/orchestrator-agent.md`
- [x] Orchestrator updated with state file write instructions at each transition event (phase start, completion report, reviewer verdict, NEEDS_REVISION, APPROVED, FAILED, completion)
- [x] Orchestrator updated with Resume protocol at session start
- [x] `plans/*-state.json` added to `.gitignore`
- [x] `mcp__project-tools__get_plan_status` reads state file first, falls back to plan markdown
- [x] `mcp__project-tools__update_progress` also appends to `state.notes[]` when state file exists
- [ ] At least one real session run with state file: state correctly reflects phase progression and is readable at session start
- [ ] Human decisions pending list tested: item added on reviewer flag, removed after human decides

## Dependencies
- Issue #016 (MCP server) — optional integration; state file is useful standalone but integrates cleanly with `get_plan_status` if #016 is implemented
- No code changes — all changes are to orchestrator agent docs and `.gitignore`

## Agent Assignment
Orchestrator session (no specialist agent required — changes are to orchestrator docs and gitignore).

## Progress Notes
<!-- Updated by agents during execution -->
- 2026-03-13: Issue created from agentic techniques gap analysis.
- 2026-03-13: Implemented. Resume protocol and State File section added to orchestrator-agent.md. State file write instructions added at every transition point in Phase 1 and Phase 2. MCP get_plan_status updated to prefer state file; update_progress syncs to state.notes[]. Two DoD items remain as runtime verification (require an actual orchestrated session).
