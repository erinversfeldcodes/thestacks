---
name: staff-campaign
description: Apply the full range of the Staff Engineer's capabilities across the codebase and produce ONE sequenced remediation plan — reconnaissance inventories, per-subsystem design surveys, phase assessments, a whole-product drive, then synthesis that clusters findings by root cause and orders them into dependency-aware waves. Use for "/staff-campaign", "apply the staff engineer to the whole codebase", "put together a plan to bring this up to standard", "what's our cleanup/remediation plan", or before committing to a big refactor or a new phase.
---

# staff-campaign

The Staff Engineer's **Mode D** — the only mode that composes the others. Modes A, B and C each end
at a local verdict; a campaign runs them across the codebase and synthesises everything into a
single ordered implementation plan.

Composition is where most of the value is: the same root cause typically surfaces as five
unrelated-looking findings in five subsystems, and only a cross-scope pass can see that.

**This produces a plan, not changes.** Execution belongs to **Mode E (`staff-execute`)** or the
orchestrator — and note that Mode E had to be *created* after this campaign, because "now implement
the plan" previously had no harness at all: no autonomy contract, no exit criteria, no state model.
That vacuum is what produced continuous pausing and waves reported done that weren't. Hand off to a
mode, never to improvisation.

## Input

Optional scope hint (a set of subsystems, or "everything"). Also worth asking for if not offered:
**what the campaign is in service of** — Stage 0 needs a governing goal, and if the user doesn't
supply one, derive a candidate from `notes/` and confirm it before proceeding.

## ⛔ Autonomy contract — read this before Stage 0

**A campaign runs Stages 0 through 5 to completion without stopping for the human.** There is exactly
**one** stop: Stage 6, presenting the Remediation Plan before any issue is created. Everything before
that is yours to drive.

This is not a licence to rush — it is the opposite. It means *never trade completeness for a
check-in*. Specifically, do **not**:

- **Ask which subset to drive.** The Stage 1a inventory defines the scope. Drive all of it. If budget
  forces a cut, drive in leverage order (surfaces the frame depends on first) and state the shortfall
  in the coverage table — never ask the human to choose the cut.
- **Report interim status and wait.** No "N of M done, shall I continue?" messages. Interim output is
  permitted only when a **finding changes the plan** (a ⛔ the human may want to act on immediately,
  or a blocker that alters scope) — and even then, report and *keep going* in the same turn.
- **Stop because context is running low.** The ledger lives on disk precisely so it doesn't have to
  live in your context. See *Persistence* below.
- **Ask whether a stage or wave is finished.** Stage exit criteria are below; campaign progress is
  `just wave-status <slug>`. If a question's answer is in an artifact you can run, run it.
- **Stop on an external blocker.** See *Blocker protocol* below.
- **Ask permission for anything reversible** — deploying a preview, minting test sessions, restarting
  a preview machine, reading the preview DB, probing and reverting. All in scope, none need asking.

If you find yourself drafting a message that ends in a question mark or offers the human options,
you are almost certainly about to violate this contract. Delete it and do the work instead.

## Blocker protocol — record, route around, continue

An external blocker is **not** a stop. On hitting one: record it as a platform finding in the ledger,
find the cheapest route around it, and continue. Only if a blocker makes the **entire campaign**
impossible do you surface it and halt.

| Blocker | Route around |
|---|---|
| Vision/GPU quota or spend limit | Deploy core-only (`SKIP_VISION=1`); drive everything else; mark the vision rows blocked with the reason |
| A capability looks unavailable | **Check how `e2e/tests/helpers.ts` does it first.** If the MCP lacks a feature (e.g. offline emulation), reach for `javascript_tool` — patch `XMLHttpRequest.prototype.send` for transport failures (`fetch` is a no-op for `elm/http`) |
| Real-email preview → unreadable mailbox | Read tokens from the Neon preview branch via `mcp__Neon__run_sql`, or use `/api/test/confirmation-token` |
| Staged Fly secret not taking effect | `fly secrets deploy` — a `machine restart` does **not** apply staged secrets. Expect it to invalidate sessions (`boot_id` claim) and re-mint |
| Preview cold-start 502 | Warm `/api/health` and retry. Not a finding |

## Persistence — the ledger lives on disk, not in your context

Write the Walkthrough Ledger to a file **and update it as you go**, not at the end. Same for the
findings list. A campaign is routinely larger than one context window; persisted state is what makes
that a non-event instead of a reason to stop. If context is exhausted mid-campaign the work resumes
from the ledger — so the ledger must always be current enough to resume from.

**Budget discipline:** the main loop's context is a scarce resource reserved for the **walkthrough**
(serial, needs the browser) and the **synthesis** (needs every finding in one head). Everything else
— reconnaissance inventories, per-subsystem design passes, test surveys, coverage maps — goes to
subagents, whose context you do not pay for. Do not read large files into the main loop that a reader
could summarise. Do not narrate. Screenshots are expensive: capture them for visual findings, use
`get_page_text` for everything else.

## Steps

1. **Adopt the persona.** Read `docs/agents/staff-engineer-agent.md` in full and operate as the
   Staff Engineer, Mode D. Every cross-cutting section applies: Economy, the Bug-Catching Ladder,
   Goal Grounding, the Evidence Standard, The Drive, Test Critique, Simplification, the severity
   registers, the tone contract, and the boundaries.
2. **Run Mode D's stages 0–6 as written**: frame from `notes/` → **surface inventory + the absence
   pass + the Comprehensive Walkthrough on a preview stack** → reconnaissance → deep passes →
   synthesis by root cause and leverage → sequencing → mandatory stop.
2a. ⛔ **Stage 1c — the absence pass — is mandatory, and is what the 2026-07-27 run skipped.** Stage
   1a enumerates routes and `Page/` modules, so it can only find what already exists; the
   third-spaces map (US-3.1.1) had no route, no page and no story file, so nothing inventoried it
   and a human had to notice. Run Mode C's **six-direction gap analysis** and **"Finding what nobody
   wrote"** over the scope, and diff `notes/` intent against the story corpus. **No Stage 4 until
   every finding is either spec'd into a story file or recorded as a deliberate exclusion.**
3. ⛔ **The walkthrough is Stage 1 and nothing else starts until it is done.** Deploy a preview
   (`bash scripts/deploy-preview.sh`), authenticate with the recipe in the agent file's Drive
   section, and walk **every** surface from the Stage 1a inventory — including the upload/vision
   loop, since Modal is available. Fill the Walkthrough Ledger unfiltered: app bugs, ugly or
   incoherent surfaces, suspected code smells, story mismatches, stories that should exist and
   don't. Screenshots throughout; server logs watched throughout.
4. **Respect the stage order and say why it exists.** The walkthrough *aims* the code survey — brief
   each reader with what you actually observed in its subsystem, not with a generic survey request.
   Synthesis before sequencing; the human stop before any issue exists.

## Stage exit criteria — how you know a stage is done without asking

Without these you will keep pausing to ask whether you've done enough. Each stage is complete when
its criterion is objectively met; then you move on **in the same turn**.

| Stage | Done when |
|---|---|
| **0 Frame** | One sentence + a `notes/` citation + a derived ordering principle, all written down. |
| **1a Inventory** | Every route in the router and every `Page.*` module enumerated to a checklist file, each tagged in-scope / context, with a total count. |
| **1b Walkthrough** | Every in-scope row has a verdict and a ledger line — **including the ones that were fine**. Blocked rows say why. "N of M driven" is computable from the ledger. |
| **2 Reconnaissance** | Every inventory in the Stage 2 list has returned numbers (subsystem map, test inventory + coverage map, token drift, dead code, suite baseline) **and the Wiring Trace sweep has run** — every boundary set-difference computed, plus the zero-row sweep over every pipeline output table and `oban_jobs`. |
| **3 Deep passes** | One design pass per bounded subsystem in scope, each briefed with the walkthrough's findings for that subsystem; every ⛔/🟧 candidate has **read + run** evidence; load-bearing test claims have a **mutation probe** with verbatim output. |
| **4 Synthesis** | Every finding is assigned to a root cause; each root has its symptoms listed as acceptance criteria and a stated leverage; the ladder-wins group exists. **A flat list of findings means this stage is not done.** |
| **5 Sequencing** | Every accepted root sits in a numbered wave, each wave naming the sequencing rule that placed it, with sizes and dependencies. |
| **6 Present** | ⛔ **The one stop.** Plan written to `plans/staff-campaign-<date>.md` **and** `plans/staff-campaign-<date>-state.json` (per-wave, per-item, each naming its backing issue). `just wave-status <slug>` runs clean. No issue created yet. |

**Cross-cutting instruments are not optional and are part of Stage 3's criterion.** A campaign that
reaches synthesis without having produced any mutation probes, any Reference Corpus citation, any
Simplification candidates goal-checked against `notes/`, or any Bug-Catching-Ladder analysis has
skipped most of the persona and must go back.

## Scale and delegation

A full campaign is large. Parallelise the independent parts — reconnaissance inventories and
per-subsystem Mode A passes are independent and should run concurrently as subagents. The
**walkthrough** and the **synthesis** are **not** parallelisable: the walkthrough must be one
continuous sitting (cross-surface coherence cannot be assembled from separate drives), and synthesis
needs every finding in one head.

**Mutation probes cannot run concurrently in one working tree** — each agent's `git diff --stat`
hygiene check would see the others' probes. Serialise probing, or give probing agents their own
worktrees (noting worktrees lack the gitignored `notes/`, so goal-checked work stays in the main
tree).

If the codebase is too large for one pass, scope the campaign to the subsystems the frame depends
on and **say so in the coverage section** — a partial campaign that declares its edges is far more
useful than one that implies completeness it doesn't have. Decide that yourself from the frame; do
not ask the human to pick.

**Consider a Workflow for Stages 2–3.** They are the parallelisable bulk of the campaign (per-subsystem
design passes, test surveys, coverage maps — independent, fan-out shaped) and running them as a
`Workflow` script keeps the orchestration deterministic instead of model-driven, which removes the
main source of drift and pausing. The shape that works: main loop does Stage 1 (browser, serial) →
`Workflow` fans out Stages 2–3 → main loop does Stages 4–6 (synthesis needs one head). Probing must be
serialised or worktree-isolated inside that workflow.

## Output

The **Remediation Plan** (format in the agent file), written to
`plans/staff-campaign-<YYYY-MM-DD>.md` after approval: the frame and ordering principle, an honest
coverage table, reconnaissance numbers, root findings clustered with their symptoms and leverage,
the ladder-wins group, dependency-ordered waves of issues, what's deliberately excluded, and what
the whole thing costs and buys.

Then, **on human approval only**: **one epic issue per wave** via `create-issue`, in dependency
order, each wave's items recorded as **phases inside its epic** (not as invented ticket files — the
orchestrator spins out the real children during its own flow, and a cited `#NNN` with no backing
file is its own defect). Execution is **Mode E (`staff-execute`)**, which forms the epics, writes
the persona's bar into their DoD, and drives the orchestrator's Epic Parallel Execution — the flow
that already works and is ticket-driven.

⚠️ **Emitting waves of ad-hoc labels instead of epics is what broke the 2026-07-27 handoff.** `G1`,
`G4`, `C3`, `P7` are a work-unit type no tooling here reads: no issue file, no DoD, no state. The
campaign could not hand off to the machinery that works, so the plan was carried by hand and
execution happened outside any harness.

## Guardrails

- **Frame first.** No governing goal, no campaign — you'll produce a wish-list that gets ignored.
- **Drive before you plan, on a preview, comprehensively.** A partial drive done late produces
  *confidently wrong* conclusions, not merely incomplete ones. State "N of M surfaces driven"; an
  undriven surface caps every verdict about it at PARTIAL, and any wave whose scope covers undriven
  surfaces must say so in the wave itself.
- **Check the test suite before declaring anything impossible.** If a capability seems unavailable,
  find how `e2e/tests/helpers.ts` already does it.
- **Cluster, don't list.** A raw concatenation of every subsystem's findings is not a plan. Root
  causes with their symptoms as acceptance criteria; leverage stated per item.
- **Sequence deliberately.** Deletions before refactors; contracts before consumers; guarantees
  before the refactors needing them — but only for tests that survive the refactor; ladder climbs
  before retiring the tests they replace.
- **Coverage honesty.** State what you surveyed, drove, probed, and skipped. Implied completeness
  is the failure mode that makes a plan dangerous rather than merely incomplete.
- **Plan, don't implement.** No production edits (mutation probes only, always reverted). Hand
  execution to the orchestrator.
