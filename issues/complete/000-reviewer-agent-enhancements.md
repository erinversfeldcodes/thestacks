# Issue #000: Reviewer Agent Enhancements

## Summary
Before beginning Phase 1B implementation, all seven reviewer agents were audited against the project's review requirements and found to have consistent structural gaps. This issue documents what was missing, why it mattered, and how the enhancements address each gap.

## User Stories
Not directly tied to a user story — this is internal tooling for the agent-driven development workflow.

## Goal
All seven reviewer agents systematically surface: (1) full user story concordance, (2) test quality not just presence, (3) performance concerns per stack, (4) security as a first-class axis, and (5) researched alternative approaches — so the human mediator has complete information at review time.

## Technical Requirements
- Each reviewer must have six explicit review axes: Task Completion & User Story Concordance, Language Community Standards, Test Correctness & Completeness, Performance, Security, Alternative Approaches Research.
- User story concordance must trace every listed story end-to-end, not sample one.
- Alternative Approaches Research is mandatory even on an APPROVED verdict.
- The report format must have a named section for each axis — no axis can be skipped.
- Security violations must be listed as FAILED conditions in severity guidelines.

## Definition of Done
- [x] All 7 reviewer agents updated with 6-axis structure
- [x] Each reviewer has language-specific performance and security checks
- [x] Each reviewer has language-specific test completeness criteria
- [x] Report format updated in each reviewer to require all six sections
- [x] Alternative Approaches Research is mandatory (not conditional on verdict)

## Dependencies
None — self-contained documentation change.

## Agent Assignment
Completed by orchestrator session (no specialist agent required).

## Progress Notes
Completed prior to Phase 1B kickoff. All seven reviewers rewritten in the same session.

---

## Why This Was Needed

The reviewer agents existed in a three-axis structure — Task Completion, Language Community Standards, and Project Coding Standards — that was adequate for catching formatting, linting, and DoD checklist failures, but insufficient for the role reviewers are meant to play in this project's workflow.

The review cycle is the primary quality gate between agent-written code and a human commit. The human mediates between the reviewer's verdict and the implementer, deciding which findings to accept, push back on, or discard. For this to work well, the reviewer needs to surface everything the human would want to know — not just "does the code pass credo?" but "is this the right approach?", "will this scale?", "is there a better library for this?", and "are the tests actually testing the right things?"

The original agents could not do this. The gaps fell into five categories.

---

## Gaps Identified and How Each Was Addressed

### 1. User Story Concordance was superficial or absent

**The problem:** The Elixir reviewer had a single line: "Trace through at least one user story interaction." The other six reviewers had nothing equivalent. A reviewer that checks one story out of five, or none at all, can approve an implementation that silently omits a user-facing requirement.

**The fix:** Every reviewer now has a dedicated **User Story Concordance** axis. For every story listed in the issue file, the reviewer must trace the full flow end-to-end — from the entry point (HTTP request, user interaction, config load, schema definition) through to the output (response, rendered view, wire format, DB state). Criteria must be verified, not assumed. This is not optional and does not stop at one story.

---

### 2. Tests were checked for presence, not quality

**The problem:** The original agents checked whether tests existed (via the testing standards file) but had no criteria for evaluating whether those tests were any good. A test suite full of `assert result != nil` assertions or tests that only exercise the happy path would pass review unchallenged.

**The fix:** Every reviewer now has a dedicated **Test Correctness & Completeness** axis with two distinct concerns:

- **Correctness**: Do assertions test behaviour, not implementation details? Would a subtly wrong implementation still pass the test? Are mocks realistic?
- **Completeness**: Is there coverage for error paths, boundary conditions, edge cases, and failure modes — not just the happy path?

Each reviewer also has language-specific completeness criteria: Elixir reviewers check worker idempotency tests; Elm reviewers check that all `RemoteData` states and union type variants are covered; Python reviewers verify HMAC rejection and malformed input are tested; Rust reviewers check for property-based tests on price parsing and ISBN validation; and so on.

Test performance is also flagged — slow tests that block CI feedback loops are noted.

---

### 3. Performance was not a review concern

**The problem:** None of the original reviewers had any performance checks. Code could be approved with N+1 queries, blocking calls in async contexts, Docker images with no layer caching, or Elm pages that re-render the full model on every keystroke. These don't surface in linting or formatting checks, and they compound quietly until they become production problems.

**The fix:** Every reviewer now has a dedicated **Performance** axis tailored to the concerns of each stack:

- **Elixir**: N+1 query detection, index utilisation, Oban worker design, GenServer blocking calls, Finch connection pool sizing
- **Elm**: Unnecessary full-model re-renders, decoder efficiency, over-active subscriptions, missed HTTP parallelism opportunities
- **Python**: Blocking calls in async context, HTTP client lifecycle (per-request vs reused), Pydantic overhead on hot paths, inference timeouts, startup time
- **Platform**: Docker layer ordering for cache efficiency, final image sizes, CI job parallelism, cache hit rate, Fly.io cold start behaviour
- **Database**: Query plan coverage, index overhead on write-heavy tables, dbt materialisation strategy, partition candidates, migration lock duration
- **Rust**: Unnecessary clones, HTTP connection reuse, HTML parsing efficiency, retry/backoff strategy
- **Protobuf**: Message size, large repeated fields indicating wrong abstraction, encoding efficiency of field types

---

### 4. Security was buried, not first-class

**The problem:** Security checks existed as a single bullet point under "Project Coding Standards" in every reviewer. This meant they were easy to overlook, not systematically checked, and not reflected in the report format. A reviewer could return APPROVED without explicitly verifying auth, input validation, or GDPR compliance.

**The fix:** Security is now a dedicated **Security** axis in every reviewer, with language-specific checks that must be explicitly assessed and reported. The report format has a dedicated Security section that must be filled in — it cannot be skipped. Severity guidelines explicitly call out security violations as FAILED conditions.

---

### 5. Alternative approaches were never researched

**The problem:** The original reviewers had no instruction to consider whether the implementation was using the right approach at all. They could only judge the implementation against its own plan and the existing standards. This meant the human never received input on whether a different library, pattern, or architectural choice might be worth considering — the information asymmetry between the agent (which can research broadly) and the human (who is working from the plan) was left unaddressed.

**The fix:** Every reviewer now has a mandatory **Alternative Approaches Research** axis. Before returning a verdict, the reviewer must actively research:
- Alternative libraries or tools for core concerns
- Alternative patterns or architectures used by the community for similar problems
- Known footguns, deprecation notices, or community debates about the chosen approach
- Performance optimisation techniques specific to the workload

Each finding is presented as: **what** the alternative is, the **tradeoff** against the current approach, and whether it is worth raising now or deferring. The human then decides what to discuss and whether to incorporate any suggestion.

This section is mandatory even on an APPROVED verdict. An approved implementation may still benefit from alternatives the human can consider for future iterations.

---

## Files Modified

- `docs/agents/reviewers/elixir-reviewer.md`
- `docs/agents/reviewers/elm-reviewer.md`
- `docs/agents/reviewers/python-reviewer.md`
- `docs/agents/reviewers/platform-reviewer.md`
- `docs/agents/reviewers/database-reviewer.md`
- `docs/agents/reviewers/rust-reviewer.md`
- `docs/agents/reviewers/protobuf-reviewer.md`

---

## Relationship to the Wider Agent System

These changes affect only the reviewer layer. Implementation agents (elixir-agent, elm-agent, etc.) are unchanged — they continue to focus on building. The orchestrator protocol is unchanged — it still invokes reviewers after each implementation phase and mediates the result with the human.

The review cycle now operates as: **implement → review across six axes → human mediates → accept/revise/discard → commit**. The human remains the decision-maker; the reviewer's expanded scope means the human has more complete information at the mediation step.
