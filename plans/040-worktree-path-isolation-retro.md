# Retrospective: Worktree Path Isolation
**Issue**: #040
**Date**: 2026-03-19
**Phases completed**: 2
**Agents involved**: platform-agent (Phase 1), orchestrator direct (Phase 2)

---

## What Worked Well

- **Research was fast and thorough.** The Explore subagent identified all 23 affected files, confirmed `symlinkDirectories` was never implemented, and found the orchestrator-agent.md already had the rule written — all before planning began. This made the plan precise with no unknowns.
- **Platform-agent executed cleanly in one pass.** Zero revision cycles. The fix was mechanical (global string replace) and the self-verification grep left no ambiguity.
- **The orchestrator-agent.md rule was already written correctly.** The "Worktree Path Isolation (Issue #040)" section anticipated this fix exactly, so no orchestrator protocol change was needed — only the specs it delegates to required updating.
- **Human approved symlinkDirectories removal at planning time**, which let Phase 2 close without a separate decision point.

---

## What Caused Friction

- **The issue predated any plan file**, so there was no state to resume from — the orchestrator had to reconstruct context from scratch. Minor, but worth noting for issues that span sessions.
- **`mcp__project-tools__update_progress` was unavailable** in the platform-agent session (MCP not available in that context). Progress notes were not appended to the issue file during execution. No blocking impact, but the progress trail is missing.
- **DoD item 5 ("two agents editing same file produce separate copies") cannot be automatically verified** without actually running two parallel worktree agents against the same file. The fix addresses the root cause (absolute paths), but there is no smoke-test or CI check confirming isolation end-to-end.

---

## What Should Change in the Agent System

| File | Change | Addresses friction point |
|------|--------|--------------------------|
| `docs/agents/orchestrator-agent.md` | Add a note in Phase 0 (Issue & Branch Setup) that when an issue is started fresh without a prior state file, the orchestrator should check `issues/NNN-*.md` progress notes for any prior partial work | Stale context reconstruction |
| `docs/agents/orchestrator/researcher-agent.md` | Add a note that `mcp__project-tools__update_progress` may be unavailable in some session contexts; log progress via completion report instead | MCP unavailability in subagent sessions |
| `scripts/mcp/project_tools.py` | Add a `validate_worktree_isolation()` tool that runs the grep check and returns pass/fail — callable from orchestrator after worktree agent phases to confirm no absolute paths leaked | Lack of automated end-to-end isolation verification |

---

## Suggested Issues

- [ ] Implement `validate_worktree_isolation()` in project_tools.py — a tool that greps `docs/agents/` for absolute paths and verifies two simultaneously-running worktree agents produce separate file copies, to provide automated end-to-end confirmation of Issue #040's fix.
- [ ] Implement symlink creation in `create_worktree()` — add the logic to symlink `deps`, `_build`, `node_modules`, and `apps/vision/.venv` from the main tree into each worktree, reducing setup time for parallel agent phases. Was deferred from Issue #040 due to shared-state risk requiring careful design.
