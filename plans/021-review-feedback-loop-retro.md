# Retrospective: Structured Feedback Loop from Reviews to Agent Prompts
**Issue**: #021
**Date**: 2026-03-13
**Phases completed**: 2
**Agents involved**: platform-agent (Phase 1), python-agent (Phase 2)

---

## What Worked Well

- **Parallel Phase 1 delegation**: Feedback template creation and orchestrator doc updates ran in parallel since they touched different files. Both completed without conflicts.
- **Format-first approach**: Creating the feedback templates in Phase 1 before implementing the MCP parser in Phase 2 ensured the parser was built against the real file format, not an assumed one.
- **Regex field extraction**: The python-agent correctly identified that the feedback format uses `**Field:** value` (colon inside bold markers) and adjusted the regex accordingly. This would have been a subtle bug if missed.
- **Growing MCP test suite**: The test file now has 20 tests across multiple tool functions (run_test_suite + get_feedback_summary), building a solid regression safety net.

---

## What Caused Friction

- **No friction observed**: This issue was clean — clear spec, straightforward implementation, no ambiguity in the feedback entry format.

---

## What Should Change in the Agent System

| File | Change | Addresses friction point |
|------|--------|--------------------------|
| N/A | No changes needed — this issue was smooth | N/A |

---

## Suggested Issues

- [ ] Feedback log dashboard — Add a summary view (e.g., `just feedback-report`) that shows open feedback counts per agent, enabling quick triage during prompt improvement sessions
