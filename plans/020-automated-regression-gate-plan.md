# Plan: Automated Regression Gate Before Review
**Issue**: #020
**Created**: 2026-03-13
**Status**: Approved

## Context
After a specialist completes work, an automated test suite run catches mechanical failures before the reviewer sees the code. Combined with #018 (test-first) and #019 (self-review), this eliminates virtually all pre-review mechanical failures.

## Research Summary
The MCP server (`scripts/mcp/project_tools.py`) uses `mcp.server.fastmcp.FastMCP` with a single dependency (`mcp>=1.26.0`). It exposes 6 tools (get_issue, list_issues, next_issue_number, update_progress, get_plan_status, get_agent, create_issue). Adding `run_test_suite` follows the same pattern. The orchestrator's Phase 2B (Spec Coverage Gate) is the insertion point for the automated test gate — it runs after the specialist submits but before review.

## Approach Options
- **Option A (chosen):** `run_test_suite` MCP tool + orchestrator 2B update — structured MCP output, extensible for worktree isolation (#022). Recommended.
- **Option B:** Shell script — less structured, harder to extend. Not recommended.
- **Option C:** Inline commands in orchestrator — duplicates mapping, no structured parsing. Not recommended.

## Phases

### Phase 1: MCP Tool Implementation
**Objective**: Implement `run_test_suite` in `scripts/mcp/project_tools.py`
**Agent(s)**: python-agent
**Steps**:
1. Add `run_test_suite(domain: str, worktree_path: str | None = None) -> dict` tool
2. Domain→command mapping: elixir→`mix test` (apps/core/), elm→`npx elm-test` (frontend/), rust→`cargo test` (apps/scraper/), python→`pytest` (apps/vision/)
3. Return structured result: `{domain, passed, summary, output, command}`
4. Handle subprocess execution with timeout, capture stdout+stderr
5. Write tests verifying: valid domain returns result, invalid domain returns error, return structure matches spec
**Test Command**: `cd scripts/mcp && python -m pytest`
**DoD Items**:
- [ ] `run_test_suite` MCP tool implemented for elixir, elm, rust, python domains
- [ ] Tool tested: passing suite returns `passed: true`; deliberately broken test returns `passed: false` with output

### Phase 2: Orchestrator Protocol Update
**Objective**: Update orchestrator Phase 2B with automated test gate before spec coverage check
**Agent(s)**: platform-agent
**Steps**:
1. Rename current 2B to include test gate as first step
2. Add: after receiving completion report, call `run_test_suite` for relevant domain(s)
3. If passes: proceed to spec coverage gate
4. If fails: return failure output to specialist, count as revision cycle
5. Document the failure message format
**Test Command**: N/A (documentation only)
**DoD Items**:
- [ ] Orchestrator Phase 2B updated with automated gate step
- [ ] Failure message format documented and implemented

## Open Questions
None.

## Integration Handoffs
Phase 1 (python-agent) produces the MCP tool. Phase 2 (platform-agent) references it in the orchestrator protocol. Phase 2 depends on Phase 1 being complete.
