# Issue #021: Structured Feedback Loop from Reviews to Agent Prompts

## Summary
When a reviewer returns NEEDS_REVISION, the reason is valuable signal about a gap in the specialist agent's prompt. Currently that signal lives only in the human's head. A structured feedback log in `docs/agents/feedback/` captures each reviewer finding, enabling systematic prompt improvements rather than ad-hoc ones.

## User Stories
Not directly tied to a user story — internal tooling for the agent-driven development workflow.

## Goal
After 10 implementation cycles, the elixir-agent prompt has been updated to emphasise the specific things the elixir-reviewer keeps catching. Revision cycle frequency trends downward over time as the feedback log drives prompt improvements. The retrospective (Issue #014) stops being the only mechanism for agent improvement.

## Technical Requirements

### 21.1 — Feedback Log Directory

Create `docs/agents/feedback/` with one file per specialist:

```
docs/agents/feedback/
  elixir-agent.md
  elm-agent.md
  rust-agent.md
  python-agent.md
  platform-agent.md
  database-agent.md
  (etc.)
```

Each file is a running log of reviewer findings for that specialist. Format:

```markdown
# Feedback Log: elixir-agent

## 2026-03-13 — Issue #014, Phase 2
**Reviewer axis:** Code Quality
**Finding:** Missing typespecs on 3 public functions in Stacks.Shelving
**Root cause:** Agent prompt does not explicitly require typespecs on all public functions
**Prompt change needed:** Add to standards section: "Every public function must have a @spec annotation"
**Status:** open / applied (link to commit)

---
```

### 21.2 — Orchestrator Feedback Writing

The orchestrator gains a step in Phase 2D (Act on Review Result):

> When the reviewer returns NEEDS_REVISION:
> - For each finding, assess whether it indicates a gap in the specialist's prompt
> - If yes: append a structured entry to `docs/agents/feedback/<specialist>.md` using the format above
> - Mark status as `open`

This is lightweight — the orchestrator only appends when there's a clear prompt-level lesson. Not every NEEDS_REVISION triggers a feedback entry.

### 21.3 — MCP Tool: `get_feedback_summary`

Add to `scripts/mcp/project_tools.py`:

```python
get_feedback_summary(agent_name: str | None = None) -> list[FeedbackEntry]
```

Returns open feedback entries for one agent (or all agents if omitted). Used when:
- The orchestrator is about to invoke a specialist and wants to brief it on known gaps
- A human is doing a prompt improvement session

### 21.4 — Prompt Improvement Workflow

Periodically (or as a dedicated task), the human runs:
1. `get_feedback_summary()` to see all open entries
2. Reviews and decides which to apply
3. Updates the relevant agent `.md` file
4. Marks the feedback entry as `applied` with a link to the commit

This closes the loop: reviewer findings → feedback log → prompt improvement → fewer findings.

### 21.5 — Orchestrator Briefing

When invoking a specialist, if `get_feedback_summary(agent_name)` returns open entries, the orchestrator includes a brief "Known gaps to watch for" section in the invocation prompt. This is a short-term fix while the prompt update is pending.

## Definition of Done

- [ ] `docs/agents/feedback/` directory created with template file for each specialist
- [ ] Feedback entry format documented in each file's header
- [ ] Orchestrator Phase 2D updated to append feedback entries on NEEDS_REVISION
- [ ] `get_feedback_summary` MCP tool implemented
- [ ] Orchestrator invocation template updated to include known-gaps section when feedback exists
- [ ] At least one feedback entry written and used to improve a specialist prompt

## Dependencies
- Issue #016 (MCP server) — extends project_tools.py
- Issue #014 (retrospective mechanism) — complements this; retrospective is session-scoped, feedback log is persistent

## Agent Assignment
- **platform-agent** for orchestrator-agent.md changes and feedback directory scaffolding
- **python-agent** for MCP tool

## Progress Notes
<!-- Updated by agents during execution -->
- 2026-03-13: Issue created from agentic techniques feedback.
