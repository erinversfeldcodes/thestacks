# Complete: Specialist Self-Review Before Handoff
**Issue**: #019
**Completed**: 2026-03-13

## Summary
Added a self-review step to all specialist agents and classified reviewer axes as mechanical/judgment. Specialists now check mechanical axes (formatting, linting, typespecs, conventions) before submitting completion reports. Reviewers spot-check self-reviewed axes and focus on judgment calls (alternative approaches, security threat model, forward compatibility, architectural fit).

## Files Modified (17)
- `docs/agents/elixir-agent.md`, `elm-agent.md`, `python-agent.md`, `rust-agent.md`, `database-agent.md`
- `docs/agents/platform-agent.md`, `partner-agent.md`, `protobuf-agent.md`, `security-agent.md`, `testing-coordinator-agent.md`
- `docs/agents/reviewers/elixir-reviewer.md`, `elm-reviewer.md`, `rust-reviewer.md`, `python-reviewer.md`, `database-reviewer.md`, `platform-reviewer.md`, `protobuf-reviewer.md`

## DoD Items
- [x] All specialist agent docs updated with Self-Review subsection
- [x] All specialist completion report formats updated with Self-Review section
- [x] All reviewer docs updated noting that self-reviewed axes can be spot-checked
- [x] Mechanical vs judgment axis distinction documented per reviewer
