# Retrospective: Batch Execution — Issues #026, #027, #032, #036, #037, #038, #039
**Date**: 2026-03-14
**Issues**: 7 (4 doc-only, 2 code+doc, 1 full-stack)
**Agents involved**: researcher, elixir-agent, elm-agent, platform-agent, orchestrator (direct)

---

## What Worked Well

- **6-way parallel worktree launch**: All independent issues started simultaneously. Doc-only issues (#037, #039) completed in under 60 seconds. The full batch of 7 issues completed in ~15 minutes wall-clock time.
- **Issue dependency sequencing**: #027 (doc audit) correctly waited for #026 (user story gap analysis) to complete before launching, ensuring the new stories were available for mapping.
- **Agent self-sufficiency**: Every agent completed its task without revision cycles. Clear issue specs + focused scope = first-pass success.
- **#032 full-stack in one pass**: The cost transparency page (migration + context + Oban worker + controller + Elm page + 18 tests) was implemented by a single agent in one session with all tests passing.
- **#027 thoroughness**: The doc audit agent found and corrected dozens of stale references (Fly Postgres → Neon, shelf → bookshelf, TheStacks.* → Stacks.*) across 8 files — work that would have taken hours manually.

---

## What Caused Friction

- **Worktree path isolation failure (critical)**: All 6 worktree agents wrote changes to the main tree via absolute paths and symlinks. `docs/`, `scripts/`, `CLAUDE.md` changes from all agents landed on the same working tree simultaneously. This defeated worktree isolation entirely and made it impossible to cleanly attribute changes to individual issues for committing. Filed as Issue #040.
- **Three agents editing orchestrator-agent.md**: Issues #036, #037, and #039 all modified the same file. Because worktree isolation didn't work, their changes interleaved in one diff. Got lucky — they edited different sections — but this could easily have produced corrupted content.
- **#032 was the only truly isolated worktree**: Because its changes were in `apps/core/` and `frontend/` (not symlinked), it was the only issue with actual worktree isolation. All other issues' changes need manual `git add -p` to separate by issue.
- **Commit grouping complexity**: With 7 issues' changes on one working tree, attributing each diff hunk to its issue required manual analysis. This is the exact problem worktrees were supposed to solve.

---

## What Should Change in the Agent System

| File | Change | Addresses friction point |
|------|--------|--------------------------|
| Issue #040 | Fix worktree path resolution — agents must write to worktree paths, not main tree | Worktree isolation failure |
| `docs/agents/orchestrator-agent.md` | When multiple issues touch the same file, run them sequentially (not parallel) regardless of worktree isolation | Three agents editing same file |
| `docs/agents/orchestrator-agent.md` | Add guidance: "Before launching parallel worktrees, check for file overlap. Issues touching the same files must be serialised." | Commit grouping complexity |

---

## Suggested Issues

- [x] #040 — Worktree agents write to main tree via absolute paths (already filed)
- [ ] Add a pre-launch file-overlap check to the orchestrator — before spawning parallel agents, compute the expected file sets and warn if they intersect
