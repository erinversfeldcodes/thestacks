# staff-execute

The Staff Engineer's **Mode E** — build the plan a campaign produced.

## ⛔ Why this skill had to exist

Modes A–D are **advisory**: they end at a report and are forbidden from touching production code
(`docs/agents/staff-engineer-agent.md` → Boundaries). `staff-campaign` states it outright:
*"This produces a plan, not changes. Execution belongs to the orchestrator and specialists."*

So when a human said *"complete Wave 0 and continue implementing the plan"*, the harness had **no
mode for that**. The work happened anyway, unharnessed: no autonomy contract, no exit criteria, no
state model. The observed result, and the reason this file exists:

- **Continuous pausing**, much of it purely to report — the thing `staff-campaign`'s autonomy
  contract forbids, but that contract governs Stages 0–5 of *planning* and says nothing about
  building.
- **Waves declared finished when they were not**, twice, because campaign-level completion was
  prose. Issue-level completion has been hook-enforced for months
  (`scripts/hooks/lib/check-issue-evidence.sh`); the campaign layer used none of it.
- **Whole features missed** and only noticed later, because nothing forced a pass over what the
  plan *should* have contained.

Adding more prose telling an agent "don't pause" would not have fixed any of it. The fixes are
structural: a state file, a checkable definition of done, and a named mode with authority.

## Input

A campaign slug (`staff-campaign-2026-07-27`), optionally a wave (`--wave 0`). With no argument,
take the newest `plans/*campaign*-state.json`.

## ⛔ The autonomy contract

**You run until the wave's every item is `complete` under `just wave-status`, or you hit one of the
three stops below. Nothing else is a stop.**

Before starting, and after every item, run:

```sh
just wave-status <slug> --wave <n>     # what is actually done
just wave-status <slug> --next         # what to pick up
```

That command is the authority on progress. **You never ask a human whether a wave is done, and you
never claim it is** — `wave-status` says so or it doesn't.

### The only three stops

1. **A decision the plan did not take**, where the options lead to materially different code and
   picking wrong wastes the work. Add it to `human_decisions_pending` in the state file, keep
   building everything that does not depend on it, and raise it when you next surface.
2. **An irreversible or outward-facing action** — a push, a production deploy, a destructive
   migration, anything that sends data outside the project. Confirm these every time; prior
   approval for one does not carry to the next.
3. **A discovery that changes the plan's shape** — a root cause invalidating a wave's premise, or
   scope that belongs in a different wave. Record it, file the issue, say so, and **keep going on
   everything unaffected in the same turn.**

### Explicitly NOT stops

- **"Here's my progress, shall I continue?"** — no. Update the state file and continue.
- **A wave finished.** Start the next one. If it is the last, run the final gate and report once.
- **Context running low.** The state file is the handoff; that is its whole purpose. Update it and
  keep working until you actually run out.
- **Tests went green.** Green is the middle of the job, not the end of it — the item is not done
  until its DoD boxes carry evidence tokens.
- **An external blocker** (no API key, a quota, an unreachable service). Mark the item `blocked`
  with `blocked_on`, and move to the next actionable item. Only a blocker that stops *every*
  remaining item justifies surfacing.
- **A bug you found that is not in the plan.** File it, fix it if it is inside the item you are
  already in, otherwise leave it filed and carry on.
- **A drive found something ugly.** Register it (🟧/🟦) and continue.

If you are drafting a message that ends in a question mark, check it against the three stops. If it
is not one of them, delete it and do the work.

## Steps

1. **Adopt the persona.** Read `docs/agents/staff-engineer-agent.md` in full. Mode E inherits every
   cross-cutting instrument — the Evidence Standard, the mutation-probe protocol, the Bug-Catching
   Ladder, the Wiring Trace, the Drive, the tone contract. **Mode E is the one mode permitted to
   write production code**, and it does not lower the evidence bar to move faster; it exists
   because that bar is what makes the work worth having.
2. **Read the state file, not the prose plan, for status.** The plan says what to build and why;
   `plans/<slug>-state.json` says where things stand. When they disagree, the state file is
   authoritative for status and you fix the prose.
3. **Every item gets an issue file before code.** `issues/NNN-*.md` from `issues/TEMPLATE.md`, with
   a real DoD whose boxes name their evidence. Set `"issue": NNN` in the state file. **Do not use
   `"informal": true` for new work** — it exists only to record pre-existing unaudited items, and
   `wave-status` counts them so the debt stays visible.
4. **Build it, with the Evidence Standard intact.** Read *and* run. Mutation-probe every
   load-bearing assertion, with the failure output quoted and the revert verified clean. `just run
   just verify` before you call an item done — never bare `mix`.
5. **Drive what a person touches.** An item with a user-facing surface is not done until it has
   been used in a browser on a preview. Unit tests do not establish reachability; that is the
   defect class this campaign keeps finding.
6. **Update the state file as you go, not at the end.** `status`, `last_action`, `updated_at`. If
   your context dies mid-item, the next pass resumes from it — so it must always be current enough
   to resume from. This is the mechanism that replaces reporting-and-waiting.
7. **Commit per item**, subject-only conventional-commit messages, `git commit -- <paths>` so a
   shared branch never sweeps another agent's files. Never push.
8. **When the wave is green, report once** — what landed, what each probe proved, what is still
   `blocked` or pending a decision, and the `just wave-status` output as evidence.

## Guardrails

- **`just wave-status` is the definition of done.** Not your judgement, not a green suite.
- **No new item without an issue file.** An unauditable work unit is how false completion claims
  got cheap in the first place.
- **A stale state file is a defect**, equal to a failing test — it is what a fresh pass reads.
- **Never push, never deploy to production.** Preview deploys are yours; production is not.
- **Do not silently rescope.** A discovery becomes a filed issue, not a quiet widening of the item
  you are in.
- **Report outcomes faithfully.** If a probe did not run, say so. If an item is done but undriven,
  its status is not `complete` — say `in_progress` and name what is missing.
