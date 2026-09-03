---
name: staff-phase-audit
description: Critically assess a phase of docs/implementation-mapping.md — cross-reference it against notes/ and against the running system to find gaps in the user-story set itself (e.g. "is there a password reset story?"), and prove whether the phase's stories are actually built, genuinely tested, and observable when driven live. Evidence from reading AND running. Use for "/staff-phase-audit", "assess phase N", "are we missing user stories", "is phase N actually done", "what's the real state of the roadmap", or before planning the next phase.
---

# staff-phase-audit

The Staff Engineer's assessment of a **phase**, run through the persona in
`docs/agents/staff-engineer-agent.md` — **Mode C**. Advisory: it produces a report and proposals,
never edits the roadmap or creates issues without a human ruling.

It answers two questions:

1. **Is the story set complete?** Gaps between what `notes/` says we want and what any story
   actually delivers — the "we have no password reset story" class. Nothing else in this system
   asks this; `feature-completeness` and `test-audit` both start from a list someone already wrote.
2. **Is the phase real?** Are its stories built, genuinely tested (probed, not just green), and
   observable when driven live?

## Input

A phase identifier from `docs/implementation-mapping.md`'s phase table — `Phase 1`…`Phase 7`,
`Phase 1 (extended)`, or `Cross-cutting`. If none is given, list the phases and ask which.

## Steps

1. **Adopt the persona.** Read `docs/agents/staff-engineer-agent.md` in full and operate as the
   Staff Engineer, Mode C. Its Goal Grounding, Evidence Standard, mutation-probe protocol, Test
   Critique, severity registers, tone contract, and boundaries all apply verbatim.
2. **Run Mode C's steps 1–8 as written**: load the three corpora (intent / plan / reality) →
   build the mechanical story census → fan out readers incl. a reverse-inventory reader → run the
   suites **and drive the phase yourself on a real stack** (see below) → per-story verdicts
   (commissioning `feature-completeness` and `test-audit`, then probing their tests yourself) →
   six-direction gap analysis → mandatory stop → actions on approval.
2a. **The drive is mandatory here, not optional.** Stand up a preview
   (`SKIP_VISION=1 STACKS_SKIP_RESOLVER_PREFLIGHT=1 bash scripts/deploy-preview.sh`), open it in a
   real browser via `claude-in-chrome`, and complete every one of the phase's journeys as a person
   — arriving through the navigation, not by typing routes. Screenshot each surface, watch the
   logs, hit the empty/error/first-run states, and run the coherence sweep across the phase's
   surfaces in one sitting. Read each story's "What they see on the page" section **before**
   driving it, not after. Tear the preview down when done.
3. **Do the cheap objective part first and get it right.** The set difference between the phase
   table's story IDs, the story corpus, and the story-by-story mapping is mechanical, and two of
   the six gap directions fall straight out of it. **Read the agent file's "Census pitfalls" note
   before running it** — stories live in two homes (`docs/user_stories/US-*.md` files *and*
   narrative sections in `docs/user-stories.md`) under two ID granularities (`US-3.1` vs
   `US-3.1.1`). A naive diff reports dozens of phantom gaps that aren't real.

## Output

The **Phase Assessment Report** (format in the agent file): verdict (ON TRACK / GAPS /
MISREPRESENTED), what was run, the story census, per-story built/tested/probed/driven verdicts,
the gap table by direction, proposed missing stories, deliberate `notes/`-sanctioned exclusions,
and recommended actions.

Then, **on human approval only**: story files + mapping entries for accepted gaps, documentation
fixes for mapping drift, and tracked issues via `create-issue` for unbuilt or unguaranteed work.

## Guardrails

- **Don't assume the direction of drift.** A feature can be built and unmapped, mapped and
  unbuilt, storied and unscheduled, or shipped with no story at all. Check all six directions.
- **Code-reading does not establish "built."** Drive it. A `feature-completeness` ✅ resting on a
  code-read is PARTIAL until you've seen the real signal.
- **A phase can pass every test and still not be ON TRACK.** If the surfaces don't feel like one
  product, or a story is delivered in letter but not in spirit (JOYLESS), say GAPS and name it.
- **No experience claim without a screenshot.** Aesthetic findings need the exact path, the
  promise quoted from the story or `notes/`, and — for coherence findings — both surfaces shown.
- **Green tests do not establish "tested."** Probe the tests that claim the story.
- **No unilateral doc edits.** Never rewrite `implementation-mapping.md` / `user-stories.md` or add
  story files before the human rules on the gaps.
- **Record refusals, don't re-raise them.** A capability `notes/skills-gap-analysis.md` explicitly
  rules out is not a gap — log it as a deliberate exclusion so the next audit stops finding it.
- **If `notes/` is absent** (it's gitignored, so worktrees and fresh clones lack it), say so at the
  top and mark intent-side findings ungrounded rather than guessing at product intent.
