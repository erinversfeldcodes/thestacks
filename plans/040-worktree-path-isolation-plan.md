# Plan: Worktree Path Isolation — Fix Absolute Paths in Agent Specs
**Issue**: #040
**Created**: 2026-03-19
**Status**: In Progress

## Context
Agents spawned with `isolation: "worktree"` receive absolute paths in their prompts (e.g., `/Users/erinversfeld/thestacks/docs/...`) which resolve to the main repository tree regardless of the worktree CWD, defeating isolation. The orchestrator-agent.md already documents the fix protocol (lines 141-151); this plan executes it across all 23+ agent specs. Additionally, the aspirational `symlinkDirectories` config in `.claude/settings.json` will be removed since no code reads it.

## Research Summary
- 23 agent `.md` files embed `/Users/erinversfeld/thestacks/` absolute paths in Context Loading Requirements / Key Reference Files sections
- `symlinkDirectories` in `.claude/settings.json` lists only build artifacts (correct per DoD item 3), but is never read by any code — it is aspirational and creates confusion
- `create_worktree()` in `project_tools.py` does not create symlinks; this is deferred
- The orchestrator-agent.md worktree path isolation rule (lines 141-151) is already in place

## Approach Options
- **Option A (chosen):** Convert all absolute paths in agent `.md` files to `./`-relative paths. Relative paths work correctly in both main-tree and worktree contexts. Remove the unused `symlinkDirectories` block from settings.json. Simple, low-risk.
- **Option B:** Add path-rewriting logic to the orchestrator at prompt-construction time. More complex, fragile runtime transformation, doesn't fix the specs themselves.
- **Option C:** Implement symlink creation in `create_worktree()`. Orthogonal to the isolation bug; adds shared-state risk between parallel worktrees. Deferred to a future issue.

## Phases

### Phase 1: Update All Agent Specs to Use Relative Paths
**Objective**: Replace all `/Users/erinversfeld/thestacks/` absolute prefixes in agent `.md` files with `./` relative paths, and remove the unused `symlinkDirectories` block from `.claude/settings.json`.
**Agent(s)**: platform-agent
**Steps**:
1. Search all files in `docs/agents/` (recursively) for the pattern `/Users/erinversfeld/thestacks/`
2. In each file, replace all occurrences with `./`-prefixed relative paths (e.g., `/Users/erinversfeld/thestacks/docs/technical-architecture.md` → `./docs/technical-architecture.md`)
3. Remove the `"worktree": { "symlinkDirectories": [...] }` block from `.claude/settings.json` entirely
4. Verify no absolute paths remain across all agent specs
5. Confirm every edited file is syntactically valid Markdown
**Test Command**: `grep -r "/Users/erinversfeld/thestacks/" docs/agents/ --include="*.md"` (must return zero matches after implementation)
**DoD Items**:
- [ ] All agent `.md` files use relative paths (no `/Users/...` absolute path occurrences)
- [ ] `.claude/settings.json` `symlinkDirectories` block removed
- [ ] `grep` verification returns zero matches

### Phase 2: Verification and Close
**Objective**: Confirm the isolation rule in orchestrator-agent.md is sufficient, and mark all DoD items satisfied.
**Agent(s)**: platform-agent
**Steps**:
1. Add a brief verification note to the "Worktree Path Isolation (Issue #040)" section in `docs/agents/orchestrator-agent.md` confirming agent specs are now relative-path-clean
2. Mark all 5 DoD items in the issue file as satisfied (`[x]`)
**Test Command**: N/A (documentation only)
**DoD Items**:
- [ ] Orchestrator agent worktree section updated to confirm fix is applied
- [ ] Issue #040 DoD items all marked `[x]`

## Open Questions
None.

## Integration Handoffs
Phase 1 completes before Phase 2. No parallel execution.
