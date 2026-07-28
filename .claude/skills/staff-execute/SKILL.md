---
name: staff-execute
description: Build a staff-campaign's plan by turning each approved wave into ONE epic issue and driving the orchestrator's Epic Parallel Execution — it does not reimplement execution. Contributes the Staff Engineer persona's bar (live drive, mutation probe, wiring trace, gdpr-review) written into the epic's DoD, plus a shadow review before the PR. Runs until `just wave-status` is green, stopping only at epic mode's batched stops. Use for "/staff-execute", "implement the campaign plan", "complete wave N", "build the remediation plan", or after a campaign's Stage 6 has been approved.
---

# staff-execute

The Staff Engineer's **Mode E** — get a campaign's plan built, by **driving the orchestrator**, not
by reimplementing it.

## ⛔ What this is, and what it deliberately is not

Modes A–D are advisory: they end at a report and may not touch production code. So "now implement
the plan" had no harness, and the work happened unharnessed — continuous pausing, waves declared
finished that weren't, work units nobody could audit.

**The fix is not a new execution engine.** One already exists and works: the orchestrator's **Epic
Parallel Execution** (`docs/agents/orchestrator-agent.md` → *Epic Parallel Execution*), which is
ticket-driven — an epic root issue spins out child issues on one integration branch under a single
PR, with a child dependency DAG, per-level parallel worktrees, `just ci` as the integration gate,
and **exactly two batched stops** (kickoff and finalization). That flow has a track record. It also
already keeps the human informed *without stopping*, via an Epic State block each response.

⚠️ **The campaign's real defect was its output shape, not a missing engine.** Mode D emitted
**waves** containing ad-hoc labels (`G1`, `G4`, `C3`, `P7`) — a work-unit type no tooling in this
project reads, with no issue file, no DoD, and no state. The orchestrator's proven input is an
**epic ticket**. A campaign that emits waves cannot hand off to the thing that works, so a human
ends up hand-carrying labels into an agent that wanted a ticket.

So Mode E is a thin adapter with an opinion:

| | |
|---|---|
| **Mode D gives** | a sequenced plan of waves, root-cause clustered |
| **Mode E turns each wave into** | one **epic issue**, its items becoming the epic's phases/children |
| **The orchestrator does** | the building, in epic mode, unchanged |
| **Mode E contributes** | the persona's *bar* — written into the epic's DoD so the orchestrator enforces it — plus a Mode B shadow review of the epic diff before the PR |

The staff engineer's value here is not throughput. It is that the plan came from deep research and
sharp critique, and that the DoD the orchestrator is held to carries that standard rather than a
generic one.

## Input

A campaign slug (`staff-campaign-2026-07-27`), optionally `--wave N`. With no argument, the newest
`plans/*campaign*-state.json`.

## ⛔ Autonomy

**Run until `just wave-status <slug>` reports the wave green.** That command is the authority on
progress — you never ask a human whether a wave is done, and you never assert it yourself.

```sh
just wave-status <slug>            # roll-up: wave → epic → children → phases
just wave-status <slug> --next      # the next actionable item
```

Stops are **the orchestrator's batched epic stops, and nothing added on top**:

1. **Epic kickoff (once per wave)** — present the DAG and each child's scope.
2. **Epic finalization (once per wave)** — the cumulative diff + the epic-level PE gate, before the PR.
3. Plus the two the orchestrator already defines as unbatched: a reviewer returning
   NEEDS_REVISION twice, or a non-mechanical merge conflict.
4. Plus one Mode E owns: **a discovery that changes the plan's shape** — a root cause invalidating
   a wave's premise. Record it, file the issue, say so, and keep building everything unaffected in
   the same turn.

**Not stops:** reporting progress (use the Epic State block, which informs without asking), a child
completing, a wave completing (start the next), low context (the state files are the handoff), green
tests (green is mid-job), or one item blocked (mark `blocked_on`, move to the next ready child).

If a message you are drafting ends in a question mark, check it against that list. If it is not
there, delete it and do the work.

## Steps

1. **Adopt the persona.** Read `docs/agents/staff-engineer-agent.md` in full. Every cross-cutting
   instrument applies to the *standard you hold the work to*: the Evidence Standard (read it AND run
   it), the mutation-probe protocol, the Bug-Catching Ladder, the Wiring Trace and its zero-row
   sweep, the Drive, the severity registers, the tone contract.
2. **Turn each approved wave into ONE epic issue.** `mcp__project-tools__create_issue`, from
   `issues/TEMPLATE.md`. The wave's items become the epic's **phases documented inside the epic**
   — ⚠️ *not* separate ticket files invented up front, and never a cited `#NNN` with no backing
   file. The orchestrator spins out real child issues during its own flow, which is where that
   breakdown belongs and has always worked.
3. **Write the persona's bar into the epic's DoD.** This is Mode E's substantive contribution and
   the reason this isn't just "call the orchestrator". Each DoD box names its evidence, and for this
   campaign's recurring defect classes specifically:
   - a **live drive** for any user-facing surface — unit tests do not establish reachability;
   - a **mutation probe** on every load-bearing assertion, with the failure output quoted;
   - a **wiring trace + zero-row sweep** for anything with a pipeline behind it;
   - for a data-touching diff, the `gdpr-review` lens.
4. **Hand the epic to the orchestrator in epic mode.** Do not re-derive its DAG, its worktree
   isolation, its per-child review cycle, or its gates. `just ci` — not `just verify` — is the
   integration gate (the #119 lesson).
5. **Keep the campaign state file current** as the layer above epic state: set the wave's item
   `issue` to the epic number, mirror status, update `updated_at`. The hierarchy is
   campaign state → `plans/<root>-<slug>-epic-state.json` → per-child `plans/NNN-*-state.json`;
   `wave-status` walks all three, so keeping the top layer honest is what makes the roll-up true.
6. **Shadow-review the epic diff yourself before finalization** (Mode B, and `staff-review` already
   runs inside `finalize-pr` — don't duplicate it). You are a dissenting seat, not a gate.
7. **When the wave is green, start the next one.** Report once at the end of the last: what landed,
   what each probe proved, what is `blocked`, and the `just wave-status` output as evidence.

## Guardrails

- **Do not reimplement the orchestrator.** If you find yourself writing a child-dependency DAG, a
  worktree scheme, or a review-revision loop, stop — epic mode has all three and they are proven.
- **One epic per wave; items are phases inside it.** Ad-hoc labels are what made completion
  uncheckable. Equally, do not manufacture a ticket file per item up front — the orchestrator
  creates children as it goes, and a phantom `#NNN` is its own defect.
- **`just wave-status` is the definition of done**, not your judgement and not a green suite.
- **A stale state file is a defect** on par with a failing test — it is what a fresh pass reads.
- **Never push; never deploy to production.** Preview deploys are yours.
- **Report faithfully.** An item built but undriven is `in_progress`, and you name what is missing.
