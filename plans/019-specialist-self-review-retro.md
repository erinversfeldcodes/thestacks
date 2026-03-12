# Retrospective: Specialist Self-Review Before Handoff
**Issue**: #019
**Date**: 2026-03-13
**Phases completed**: 2
**Agents involved**: platform-agent (all phases)

---

## What Worked Well

- **Parallel batching again**: Same pattern as #018 — splitting 10 specialists into two parallel batches halved wall-clock time for Phase 1. This is becoming a reliable pattern for mechanical doc updates.
- **Research-first axis classification**: The upfront research agent mapped every reviewer's axes with mechanical/judgment classification before any edits began. This prevented guesswork and ensured each reviewer got the right tags.
- **Building on #018**: Issue #018 established the Test-First Protocol and Axis 0 sections. This issue slotted cleanly after them (Self-Review goes after Test-First Protocol; Step 0b goes after Step 0a). The layered approach worked — each issue builds on the previous without conflicts.
- **Per-stack specificity**: Rather than a generic self-review checklist, each specialist got stack-specific mechanical checks (e.g., `mix format` + `credo` for Elixir, `cargo fmt` + `clippy` for Rust). This makes the self-review actionable rather than vague.

---

## What Caused Friction

- **Mixed axes require nuance**: Axes 2–5 are often mixed (part mechanical, part judgment). The tag `(mixed — specialist checks X; reviewer assesses Y)` is informative but long. Future reviewers may find the heading lines cluttered. This is a minor readability concern, not a functional issue.
- **Completion report numbering divergence**: Different specialist agents have different numbers of completion report items (elixir has 7, partner has 5, security has 5). The Self-Review item was added as the "last" item in each, but the numbering isn't consistent across agents. This isn't wrong — each agent's report format is tailored — but it could confuse the orchestrator when parsing reports.

---

## What Should Change in the Agent System

| File | Change | Addresses friction point |
|------|--------|--------------------------|
| All reviewer docs | Consider shortening mixed axis tags to `(mixed)` with the detail in the axis body instead of the heading | Heading readability |
| `docs/agents/orchestrator-agent.md` | Add a note in the Subagent Invocation Protocol that completion report item numbers vary by specialist — parse by section heading, not by number | Completion report numbering divergence |

---

## Suggested Issues

- [ ] Standardise completion report format — Align all specialist agents to a consistent numbered item list (currently ranges from 5 to 8 items across agents)
