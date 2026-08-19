---
name: staff-survey
description: Run The Stacks Staff Engineer's stewardship survey over existing code — evidence-based design critique (read AND run), concrete rewrite sketches, system-simplification candidates goal-checked against notes/, and a test-suite audit that mutation-probes tests to find which are true guarantees, which need rewriting, and which are too mocked/artificial to keep. Produces a Design Ledger for human approval, then tracked issues. Use for "/staff-survey", "review the codebase", "how do we simplify this", "are our tests actually testing anything", "bring X up to standard", or before a cleanup/refactor phase.
---

# staff-survey

The Staff Engineer's stewardship pass over **existing** code (as opposed to `staff-review`, which
reviews a diff). Runs the persona in `docs/agents/staff-engineer-agent.md` — **Mode A**.

Answers four questions with evidence:

1. **How should this code be written instead?** — concrete rewrite sketches, not direction, with
   a bias toward *less* and toward catching bugs higher up the Bug-Catching Ladder.
2. **What can the system lose?** — simplification and deletion candidates, each goal-checked
   against `notes/` so nothing load-bearing for a planned milestone gets cut.
3. **Do the tests guarantee anything?** — per-test KEEP / STRENGTHEN / REWRITE / CONSOLIDATE /
   REMOVE verdicts, each backed by a mutation probe.
4. **Is this software to be proud of?** — for user-facing scope, judged by actually using it on a
   running stack, not inferred from source.

## Input

A scope. If none is given, **ask** — a whole-codebase survey is expensive and usually less useful
than a deep one on a subsystem. Good scopes: a Phoenix context, the Elm SPA, the event pipeline,
the scraper, one test suite, "the GDPR surface".

## Steps

1. **Adopt the persona.** Read `docs/agents/staff-engineer-agent.md` in full and operate as the
   Staff Engineer, Mode A. Its value system, Reference Corpus method, Goal Grounding, Evidence
   Standard, mutation-probe protocol, Test Critique taxonomy, severity registers, tone contract,
   and boundaries all apply verbatim.
2. **Run Mode A's steps 1–9 as written**: load context → fan out read-only readers (code rubric +
   test rubric) → read the load-bearing files yourself → **run the system for a behavioural
   baseline, and drive it in a browser if the scope is user-facing** (see **The Drive** — real
   stack, screenshots, coherence sweep, logs watched) → probe the tests → simplification pass →
   synthesise the Design Ledger → mandatory stop → issues on approval.
3. **Honour the hard rules.** Evidence for behaviour claims is a command and its output, not a
   reading. Exemplar citations are fetched and verified or dropped. Probes are reverted with Edit
   and confirmed clean via `git diff --stat` before the report is delivered.

## Output

The **Design Ledger** (format in the agent file), written to
`plans/staff-ledger-<scope>-<YYYY-MM-DD>.md` after approval, containing: the one-paragraph verdict,
what was run, what's right and must be protected, the findings ledger, simplification candidates
with goal checks, test verdicts with probe evidence, the design-it-twice appendix, and the proposed
issue breakdown.

Then, **on human approval only**, the tracked issues via `create-issue`.

## Guardrails

- **Mandatory stop before any issue is created.** The ledger is a proposal.
- **No production edits.** Mutation probes only, always reverted, never via `git checkout`.
- **No deletion by this skill** — of code or of tests. Verdicts become issues.
- **Cite `notes/` for every simplification.** If `notes/` is absent, say so and mark those findings
  goal-check pending rather than recommending deletions blind.
- **Scope honestly.** Better a deep, fully-probed survey of one context than a shallow sweep of ten.
  Say what you did not cover.
