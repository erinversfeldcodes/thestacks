# Retrospective: Automated Regression Gate Before Review
**Issue**: #020
**Date**: 2026-03-13
**Phases completed**: 2
**Agents involved**: python-agent (Phase 1), platform-agent (Phase 2)

---

## What Worked Well

- **First code+docs issue in this session**: Unlike #018 and #019 (docs-only), this issue combined Python implementation with orchestrator doc updates. The two-phase split (python-agent then platform-agent) kept each agent focused on its domain.
- **Comprehensive test coverage**: The python-agent produced 16 unit tests covering all branches — invalid domain, missing directory, timeout, output truncation, summary extraction for all 4 domains. This is exactly the kind of coverage the test-first workflow (#018) aims to enforce.
- **Clean MCP integration**: The new tool follows the exact same patterns as existing tools in `project_tools.py` — `@mcp.tool()` decorator, sync function, type hints, docstring, error dict returns. No new dependencies needed.
- **Import verification**: Running `python -c "import project_tools"` after implementation caught any syntax issues immediately — a good pattern for MCP tool development.

---

## What Caused Friction

- **No integration test**: The unit tests mock `subprocess.run`, which validates logic but not that the actual test commands work in the project. A real integration test would call `run_test_suite("elixir")` and verify it actually runs `mix test`. This is acceptable for now but leaves a gap.
- **Test-first protocol not followed**: This was a code phase, but the orchestrator didn't split it into 2A-i (write tests) and 2A-iii (implement) as defined in #018. The python-agent wrote tests and implementation together. This is the first real code issue since #018 was implemented — the new protocol wasn't exercised.

---

## What Should Change in the Agent System

| File | Change | Addresses friction point |
|------|--------|--------------------------|
| `docs/agents/orchestrator-agent.md` | Add a note that the test-first split (2A-i → 2A-ii → 2A-iii) applies to ALL code phases, including MCP tool development | Test-first protocol not followed |
| `scripts/mcp/test_project_tools.py` | Add integration test markers (`@unittest.skipUnless(os.path.exists(...))`) for real test suite execution | No integration test |

---

## Suggested Issues

- [ ] MCP tool integration tests — Add integration tests for `run_test_suite` that actually run test suites against the real project directories (gated by directory existence)
