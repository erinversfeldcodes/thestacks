# Complete: Evaluate Claude Code Agent Teams
**Issue**: #024
**Completed**: 2026-03-13

## Summary
Evaluated three orchestration approaches (Current Orchestrator, Agent Teams, Hybrid) by implementing Issue #005 (Neon Preview Branch Data Isolation) on three parallel trial branches. Measured against 10 success criteria. The Hybrid approach won: orchestrator protocol for planning, gates, and mandatory stops; Agent Teams teammates for parallel specialist execution.

## Decision
**Hybrid** — adopted as the default orchestration model.

- Agent Teams eliminated by decision rule: State Recoverability FAIL (design limitation — no session resumption for teams)
- Hybrid beat Current Orchestrator on correctness (no integration bug) and wall-clock time (~15 min vs ~18 min)
- Key finding: the orchestrator must embed cross-cutting concerns in teammate prompts at spawn time to prevent integration gap bugs

## Files Created/Modified
- `docs/agents/decisions/agent-teams-evaluation.md` — trial protocol, results, and final decision
- `docs/agents/decisions/005-current-orchestrator.md` — Branch 1 trial report
- `docs/agents/decisions/005-agent-teams-report.md` — Branch 2 trial report
- `docs/agents/decisions/005-hybrid.md` — Branch 3 trial report
- `docs/agents/decisions/005-trial-code-comparison.md` — code diff analysis across branches
- `docs/agents/orchestrator-agent.md` — added Hybrid Execution Model section and cross-cutting concern rule
- `.claude/settings.json` — added `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`
- `CLAUDE.md` — documented hybrid model in Agent System section

## DoD Items
- [x] Agent Teams documentation read and summarised
- [x] Trial protocol defined with 10 measurable success criteria
- [x] Three trial branches created from same main commit
- [x] Branch 1: Issue #005 implemented via current orchestrator — measures recorded
- [x] Branch 2: Issue #005 implemented via Agent Teams — measures recorded
- [x] Branch 3: Issue #005 implemented via hybrid approach — measures recorded
- [x] Results compared and final decision documented in `docs/agents/decisions/agent-teams-evaluation.md`
- [x] Winning approach adopted; losing branches archived or deleted
