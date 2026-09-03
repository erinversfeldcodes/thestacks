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
2. **The issues already exist — read them, do not re-derive them.** Mode D's **Stage 7** files an
   epic issue per wave and a real child issue file per item, sequenced, before execution begins. Your
   job here is to *consume* that set: `mcp__project-tools__get_issue` each one, confirm each cited
   number has a backing `issues/NNN-*.md`, and confirm each `## Dependencies` section names its
   predecessors with reasons.

   ⚠️ **If a wave's issues are missing, that is a Stage 7 failure — file them, then continue.** Do not
   improvise a breakdown in your head and do not cite a `#NNN` you have not written; a number with no
   file on disk is the specific defect that broke the 2026-07-27 handoff. `just wave-status <slug>`
   refuses a wave whose item has no backing file, so this is checkable, not a matter of care.
3. **Verify the persona's bar is in every DoD, and add it where it is not.** Stage 7 should have
   written it; your job is that no issue reaches the orchestrator without it. Each DoD box names its
   evidence, and for this campaign's recurring defect classes specifically:
   - a **live drive** for any user-facing surface — unit tests do not establish reachability;
   - a **mutation probe** on every load-bearing assertion, with the failure output quoted;
   - a **wiring trace + zero-row sweep** for anything with a pipeline behind it;
   - for a data-touching diff, the `gdpr-review` lens;
   - for an issue that **adds a gate/guard/runner**: the red run of a planted violation quoted in
     the DoD, and the runner's caller named ("NO further orphans" was once attested by a guard
     blind to the orphan that existed; a runner was proven working and left uncalled);
   - **cross-artefact propagation boxes**: deleting a symbol → docs grep (0 refs or updated);
     adding a route → nav entry or a recorded URL-only decision; building a storied feature →
     mapping status flipped. A sibling artefact left stale is how a deleted job got documented as
     a live deletion gate three days after it ceased to exist;
   - **instance-vs-class**: the DoD states which the issue closes; instance-only issues name the
     class follow-up (issue or `plans/residue-ledger.md` row) inline.
   **Close-out duty:** if an issue's notes say "remains / follow-up-class / not filed", either file
   the follow-up or add a residue-ledger row before marking the issue complete — residue recorded
   only as prose is how #347's 42 remaining sites got lost.
4. **Hand the epic and its filed children to the orchestrator in epic mode.** Do not re-derive its
   DAG, its worktree isolation, its per-child review cycle, or its gates. `just ci` — not `just
   verify` — is the integration gate (the #119 lesson).

4a. ⛔ **Every issue and epic gets a `staff-review` as it is implemented — mandatory invocation.**
   Not once per PR and not at the end: as the orchestrator completes each child issue, invoke the
   **`staff-review` skill** over that issue's diff, and record the verdict in that issue's Progress
   Notes. "Was this reviewed?" must be answerable from disk.

   The verdict stays **advisory**. DESIGN CONCERNS goes to the human — fix now, file and ship, or
   override — and never mechanically blocks. That combination is deliberate: a gate would put a taste
   judgement in the critical path of every child, while optional invocation is how the review gets
   skipped precisely on the diffs that most need it.

   This is *in addition to* the `staff-review` already inside `finalize-pr`, which sees the cumulative
   branch. A per-issue review catches a design problem while the diff is still small enough to change
   cheaply; the branch-level one catches what only shows up when the pieces sit together.

4b. ⛔ **Every wave gets its STACK reviewers too — `staff-review` is not a substitute for them.**
   `staff-review` covers design and test-truthfulness and explicitly defers standards compliance,
   idiom, schema design and contract shape to the stack reviewers in `docs/agents/reviewers/`
   (routed per `AGENTS.md`). Defer to a reviewer that never runs and the axis simply vanishes.

   That is not hypothetical. A 2026-08-20 audit of 43 issues from one campaign found **42 with a
   staff-review and 1 naming any stack reviewer** — no Elixir, Elm, database, contract, protobuf,
   python, rust or ux review happened at all, across 323 files and 26k insertions. The automated
   gates (credo, sobelow, dialyzer, elm-review, the Elm gate suite) were green throughout, which is
   exactly why nobody noticed: they cover the mechanical half and none of the judgement.

   **Run them per WAVE over the cumulative diff, by stack — not per issue.** Forty-three per-issue
   reviews is the wrong shape and will not happen; four-to-six stack reviews over what actually
   ships is the right one. Compute the touched stacks from the diff
   (`git diff --name-only <base>..HEAD`), invoke one reviewer per touched stack in parallel, and
   record each verdict in the wave's epic issue AND in the campaign state under `domain_reviews`.
   `just wave-status` refuses a completed wave whose touched stacks have no recorded verdict.
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
- **One epic per wave, with its items filed as real child issues by Stage 7.** Ad-hoc labels are
  what made completion uncheckable. The rule is not "don't file issues early" — it is **never cite a
  number with no file behind it**. Filing them up front satisfies that; inventing `G4` or `#312` in
  prose does not.
- **`just wave-status` is the definition of done**, not your judgement and not a green suite.
- **A stale state file is a defect** on par with a failing test — it is what a fresh pass reads.
- **Never push; never deploy to production.** Preview deploys are yours.
- **Report faithfully.** An item built but undriven is `in_progress`, and you name what is missing.
- **An unreviewed issue is not done.** If an issue's Progress Notes carry no `staff-review` verdict,
  it has not been reviewed, whatever anyone remembers about the run.
