# Issue #233: Self-explanatory-dashboard standard

## Summary
Codify the "every panel teaches" principle as a project standard so all dashboards (current and future)
explain their data, and enforce it with a test that every registered dashboard's panels carry a
teaching description. Child of epic **#231**; part of the current PR.

## User Stories
None — a documentation + enforcement standard for observability. Child of **#231**.

## Goal
`docs/agents/standards/dashboards.md` defines the rule (every panel: *what it measures · how · what it
means · what a spike/drop indicates*, plus naming/datasource/tone), and a test asserts EVERY dashboard
registered via `Core.PromEx.dashboards/0` has a non-trivial `description` on every data panel — so a new
undescribed panel fails CI. Retro-applies to #230.

## Scope Check
- >3 controllers? No. >2 endpoints? No. >300 LOC? No (a doc + a generalised test). Mixed concerns? No.

## Wiring
- [x] Implementation only — a standard doc + an enforcement test.

## Feature-Completeness Pre-Check
n/a — no user story.

## Technical Requirements
1. **`docs/agents/standards/dashboards.md`** — the standard: every data panel MUST carry a `description`
   with the four teaching elements; use the shared `datasource_id: "prometheus"`; row-separator panels
   exempt; the "curator's desk, not a Grafana clone" aesthetic note (`ux-reviewer.md:62`) for
   *user-facing* surfaces (this standard governs ops Grafana). Reference it from `AGENTS.md`/standards index.
2. **Generalised enforcement test** — promote #230's per-dashboard description check into a test that
   iterates EVERY entry from `Core.PromEx.dashboards/0`, loads its JSON, and asserts every non-row panel
   has a `description` of adequate length. (So #236–#240's dashboards inherit the rule automatically.)
3. Point #230's dashboard drift test at (or reuse) this shared helper.

## Reviewer Context
- The enforcement test must read the dashboard list from `dashboards/0` (not a hard-coded path) so new
  dashboards are covered without editing the test.
- This governs OPS dashboards; the user-facing "curator's desk" surface (#234/#235) has its own UX bar.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Standard doc exists + indexed | yes | ❌ (→ ✅) |
| Enforcement test over all `dashboards/0` | yes | ❌ #230 checks only its own dashboard. (→ ✅ generalised) |
| 1–13 app layers | no | n/a — documentation + test standard. |

Punch: (1) write the standard; (2) generalised all-dashboards-described test.
Verdict: baseline — 2 punch items.

## Definition of Done
- [ ] `docs/agents/standards/dashboards.md` written + referenced from the standards index.
- [ ] A test iterates all `dashboards/0` entries and fails if any data panel lacks a teaching description.
- [ ] #230's dashboard passes the generalised test.
- [ ] `just verify` passes; test audit GREEN.

## Dependencies
#230 (first dashboard — merged). Part of the current #118+#231 PR.

## Agent Assignment
elixir-agent (doc + test). Reviewer: elixir-reviewer.
