# The Completion Bar — when an issue or epic is actually "done"

> Established 2026-07-14. An issue or epic is **not complete** — and must not be
> marked complete, merged, or have its PR opened — until **every** item below is
> met. "Green `just verify`", "tests exist", or "code reads correctly" are
> necessary but **not sufficient**. This bar is the exit criterion referenced by
> every issue's Definition of Done and by the orchestrator's Phase 3 completion.

## The bar

1. **Every named user story is built end-to-end AND driven live.**
   Not code-read, not unit-tested-only. Each story's happy path is exercised
   against a **running stack** (local first — see §7 — then preview) through the
   real UI/API, observed working. A story that only passes at the state-machine
   or unit layer is *not* done. (The #124 and #122 lessons: shelf-visibility save
   and block/placement UIs "passed" unit tests + code-review while being broken or
   unbuilt; only the live drive caught it.)

2. **System behaviour is validated at every applicable layer.**
   Walk the 13 layers and prove each applicable one, or mark it `n/a` with a
   one-line reason — never a silent gap:
   API calls · auth & middleware guards · DB interactions · **event flow /
   event_log emissions** · Oban jobs · external service calls · storage · cache ·
   dbt models · Elm state machine · operational **metrics/telemetry** · performance ·
   cost tracking. Events and metrics are asserted (the counter fires, the
   `event_log` row is written with the right payload), not assumed.

3. **No dangling reviewer findings.**
   P0/P1 fixed. **P2/P3 are either fixed or explicitly de-scoped to a tracked
   follow-up issue with a written rationale** — never silently dropped. "Advisory"
   is not "ignore". The reviewers (stack + UX + contract) and the Principal
   Engineer gate must all be satisfied on the *fully integrated* branch.

4. **Logs are clean under the live drive.**
   During the live drive, the app logs (Phoenix, vision/Modal, workers) show no
   unexplained errors/500s/stacktraces attributable to the change. Pull and read
   them — a green test suite can sit atop a log full of swallowed errors.

5. **Tracking reflects reality.**
   The issue's Feature-Completeness Pre-Check table is filled with file:line +
   live-drive results, and the embedded 13-layer Test Audit is regenerated GREEN
   (0 ❌ / 0 ⚠️) as the final step. A stale "baseline, pre-implementation" audit or
   an unchecked DoD on shipped work is itself a completion defect.

6. **Integration is re-verified.**
   For epics: `just verify` is green **on the integration branch after every
   merge**, and the epic-level PE gate passes on the cumulative diff. A child green
   in isolation can break integration.

7. **Live-drive locally before burning cloud/preview credits.**
   Run the stack locally (`scripts/test-e2e.sh` / `just dev` + Playwright against
   `localhost`) and get the E2E green there first. Only then spend on a Fly/Modal
   preview. This catches the selector/contract/real-bug failures cheaply.

## How it is enforced
- Every issue's **Definition of Done** ends with "Meets the Completion Bar
  (`docs/agents/standards/completion-bar.md`) — all 7 items." (see `issues/TEMPLATE.md`).
- The orchestrator does not use completion language (Phase 3, PR-open, "done")
  until every item is demonstrably met, with evidence, on the integrated branch.
- Retro-applies: existing "complete" issues/epics may be re-reviewed against this
  bar; gaps become tracked follow-up issues.
