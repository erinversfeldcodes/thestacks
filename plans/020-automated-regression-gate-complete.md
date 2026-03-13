# Complete: Automated Regression Gate Before Review
**Issue**: #020
**Completed**: 2026-03-13

## Summary
Added an automated test suite gate that runs after specialist completion and before reviewer invocation. Implemented `run_test_suite` MCP tool supporting 4 domains (elixir, elm, rust, python) with structured results. Updated orchestrator Phase 2B to call the gate automatically — failures return to the specialist without involving the reviewer.

## Files Modified (3)
- `scripts/mcp/project_tools.py` — `run_test_suite` tool + `_extract_summary` helper
- `scripts/mcp/test_project_tools.py` — 16 unit tests (created)
- `docs/agents/orchestrator-agent.md` — Phase 2B split into 2B-i (regression gate) + 2B-ii (spec coverage gate)

## DoD Items
- [x] `run_test_suite` MCP tool implemented for elixir, elm, rust, python domains
- [x] Orchestrator Phase 2B updated with automated gate step
- [x] Failure message format documented and implemented
- [x] Tool tested: passing suite returns `passed: true`; failing returns `passed: false` with output
- [x] Orchestrator tested: failed gate returns to specialist without invoking reviewer
