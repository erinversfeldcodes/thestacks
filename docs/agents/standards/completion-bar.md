# The Completion Bar — when an issue or epic is actually "done"

> Established 2026-07-14. An issue or epic is **not complete** — and must not be
> marked complete, merged, or have its PR opened — until **every** item below is
> met. "Green `just verify`", "tests exist", or "code reads correctly" are
> necessary but **not sufficient**. This bar is the exit criterion referenced by
> every issue's Definition of Done and by the orchestrator's Phase 3 completion.

## The bar

1. **Every deliverable is built end-to-end AND driven live — a real signal flows
   the whole path and is *observed*.**
   Not code-read, not unit-tested-only. This binds **any** deliverable, not just
   named user stories:
   - **User-facing story** → its happy path is exercised against a **running
     stack** (local first — see §7 — then preview) through the real UI/API,
     observed working. (The #124/#122 lessons: shelf-visibility save and
     block/placement UIs "passed" unit tests + code-review while broken/unbuilt;
     only the live drive caught it.)
   - **Infra / observability / platform / pipeline** → a **real signal traverses
     the entire path and is observed at the far end**, not "the producing code
     exists." A metric is done when it is emitted → lands in the store → is queried
     back → renders on the dashboard/page — proven by watching a real value appear,
     *not* by reading the emit call or a synthetic-data gate. (The #248 lesson: the
     whole observability stack was structurally complete, tests green, and shipped
     **blank** because no sample ever reached the store — a gap no code-read or
     synthetic gate could see, only an end-to-end drive with a real value.)
   A deliverable that only passes at the state-machine, unit, or synthetic-data
   layer is *not* done.

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

8. **A structure-only gate is never completion proof.**
   A gate that runs on **synthetic / mock / existence** data (dashboard-render-gate
   seeding its own series, a `≥1 series` smoke, a drift/`displayed ⊆ measured`
   check, "the tests exist", "the route is wired") proves the artifact is
   *well-formed* — never that it *works with real data*. A done-claim requires **at
   least one gate that exercises the real path with real data end-to-end**. Where a
   check uses synthetic data, say so and name the companion real-path gate. (The
   #248 render-gate + `≥1 series` smoke were both green while prod was blank.)

9. **Every completion claim carries an evidence token — not a bare check.**
   A checked DoD box, a `✅` audit cell, or a "done" statement must cite *how* it
   was proven: a test name you verified exists (``mix test`` file + description),
   a command → captured output (`2259 tests, 0 failures`; the emission-gate table),
   a live-drive artifact (a screenshot / a real value observed on the page /
   captured logs), or a PR/commit ref. A check with no token is a *claim*, and a
   claim is treated as **not done**. "Report with evidence, never assertion"
   (`verify-and-followup`) applies to the tracking, not just the console.

10. **No `#NNN` is cited without a backing file.**
    Every issue/PR/phase reference points to a real `issues/NNN-*.md` (or an open
    GitHub issue/PR). A phantom `#NNN` sends the owner on a wild-goose chase and
    hides deferred work as "tracked". Deferrals are spun into a real issue
    (`create-issue`) or documented in the epic — never a dangling number.

## How it is enforced — mechanically, not on the honour system

The above is only real if something *blocks* skipping it. Three layers:

1. **The `completion-audit` skill is mandatory before any completion language.**
   Before an issue/epic is marked complete, its PR is opened, or the word "done"
   is used, run `.claude/skills/completion-audit/` — an adversarial pass that tries
   to prove the work is **not** done: every bar item cited with a real evidence
   token, every deliverable driven live (real signal observed), no structure-only
   gate standing in for a real one, no phantom `#NNN`, no stale audit / unchecked
   DoD on shipped work. It gates the orchestrator's Phase 3.

2. **A pre-Stop hook checks the tracking mechanically.**
   `scripts/hooks/lib/check-issue-evidence.sh` scans changed `issues/*.md`: a cited
   `#NNN` with no backing file **fails**; a newly-checked `[x]` DoD box or new `✅`
   audit cell with no evidence token **warns**. This catches the
   "documentation-lies" pattern at the edit boundary.

3. **The Definition of Done and the orchestrator reference this bar by contract.**
   Every issue's DoD ends with "Meets the Completion Bar — all items, each with an
   evidence token" (`issues/TEMPLATE.md`). The orchestrator does not use completion
   language (Phase 3, PR-open, "done") until `completion-audit` passes on the
   integrated branch. Retro-applies: existing "complete" issues may be re-reviewed;
   gaps become tracked follow-up issues.
