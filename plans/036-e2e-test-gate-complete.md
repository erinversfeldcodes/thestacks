# Completion: E2E Test Gate in Agent Workflow
**Issue**: #036
**Completed**: 2026-03-14
**Agent(s)**: platform-agent

## Summary
Extended the orchestrator protocol with a deploy-preview + E2E test gate between implementation and review. Added `run_e2e_gate` MCP tool with 11 tests.

## Changes
- `docs/agents/orchestrator-agent.md` — added steps 2B-iii (deploy preview + E2E gate) and 2B-iv (preview cleanup), updated reviewer prompt and test-writing prompt, extended state schema with `preview_url`, `e2e_skipped`, `e2e_skip_reason`
- `scripts/mcp/project_tools.py` — added `_parse_deploy_output()` helper and `run_e2e_gate()` MCP tool
- `scripts/mcp/test_project_tools.py` — 11 new tests (6 for parser, 5 for gate tool)
- `CLAUDE.md` — added `run_e2e_gate` to MCP tools table

## E2E gate is optional
Skipped for doc-only phases, agent prompt changes, or any phase that doesn't touch deployed code. When skipping, records `e2e_skipped: true` and reason in state file.
