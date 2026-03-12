# Plan: Test-First Agent Workflow
**Issue**: #018
**Created**: 2026-03-13
**Status**: Approved

## Context
The current orchestrator flow is plan → implement → review. This issue inserts a test-first gate so every specialist phase begins with failing tests before any production code exists. This eliminates revision cycles caused by insufficient test coverage and shifts the reviewer's job from "does this work?" to "are the tests meaningful and is the code clean?"

## Research Summary
All 10 specialist agents have a consistent "Orchestrator Integration" section with subsections: When Invoked as Subagent, Challenge the Brief, Self-Verification, Completion Report Format. All 7 reviewers have 8 numbered review axes (1–8) plus a Review Process and Review Report Format. The orchestrator's Phase 2A is a single delegation step. The completion report template (6 items) lives in the orchestrator's Subagent Invocation Protocol section.

## Approach Options
- **Option A (chosen):** Two-step delegation in orchestrator + protocol sections in specialists — splits Phase 2A into test-write and implement steps with a failing-test gate. Matches the issue spec exactly. Recommended.
- **Option B:** Single delegation with embedded test-first instructions — simpler but loses the orchestrator verification gate. Not recommended because the gate is the key value.
- **Option C:** Separate test-writing agent — over-engineered; domain specialists know their test frameworks best. Not recommended.

## Phases

### Phase 1: Orchestrator Protocol Update
**Objective**: Update orchestrator-agent.md — split Phase 2A into two-step delegation (test-write → failing-test gate → implement), update completion report format
**Agent(s)**: platform-agent
**Steps**:
1. Split Phase 2A into 2A-i (Delegate Test Writing) and 2A-ii (Delegate Implementation)
2. Add failing-test gate between 2A-i and 2A-ii — orchestrator verifies specialist returned failing test output before proceeding
3. Update completion report format template to include item 5a (Failing Test Evidence — verbatim output from test run before implementation)
4. Update state tracking descriptions to reflect two-step flow
**Test Command**: N/A (documentation only)
**DoD Items**:
- [ ] Orchestrator updated: two-step delegation (test-write then implement) with failing-test gate between
- [ ] Orchestrator completion report template updated to include failing test evidence field

### Phase 2: Specialist Agent Updates
**Objective**: Add Test-First Protocol subsection to every specialist agent's Orchestrator Integration section
**Agent(s)**: platform-agent
**Steps**:
1. For each of the 10 specialist agents, add a "Test-First Protocol" subsection after Self-Verification and before Completion Report Format
2. Content specifies: write tests first covering all DoD items, tests must fail before implementation, return failing test output as evidence, do not write production code until tests are confirmed failing
3. Include language-specific test framework reference for each agent
**Test Command**: N/A (documentation only)
**DoD Items**:
- [ ] All specialist agent docs updated with Test-First Protocol subsection

### Phase 3: Reviewer Updates
**Objective**: Add Axis 0 (Test-First Compliance) as a blocking check to every reviewer
**Agent(s)**: platform-agent
**Steps**:
1. For each of the 7 reviewer docs, insert Axis 0: Test-First Compliance before Axis 1
2. Content: Were tests written before implementation? (check for failing test evidence), Do tests cover all DoD items?, Are tests meaningful (not trivially passing)?
3. Mark Axis 0 as a blocker — NEEDS_REVISION if failing test evidence is absent
4. Update Review Process section to include Step 0: Test-First Audit
**Test Command**: N/A (documentation only)
**DoD Items**:
- [ ] All reviewer docs updated with Axis 0 (test-first compliance) as a blocker

## Open Questions
None.

## Integration Handoffs
All phases use platform-agent. No cross-agent coordination needed. Phase ordering is logical (orchestrator first, then specialists, then reviewers) but phases are independent — they could run in parallel.
