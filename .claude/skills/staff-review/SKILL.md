---
name: staff-review
description: Run The Stacks Staff Engineer's shadow review — an advisory design/taste lens (Ousterhout's deep modules, Zen-of-Python legibility, Czaplicki/Feldman/Kelley/Cro taste, economy, catching bugs earlier) over a diff, branch, or PR. Mutation-probes the diff's new tests to check that passing means something, and drives user-facing changes in a real browser. Complements, never duplicates, the standards reviewers / PE / completion-audit. Use when the user says "/staff-review", "staff review this", "what would the staff engineer think", when a design-level second opinion is wanted on a change, or as the shadow-review step inside finalize-pr.
---

# staff-review

The Staff Engineer's dissenting seat: a design-and-taste review of a change, run through the
persona defined in `docs/agents/staff-engineer-agent.md` (Mode B — Shadow Review). It is
**advisory** — it produces a verdict and a report, never a mechanical block.

## Input

One of, in order of precedence:

1. An explicit argument: a branch name, a PR number, or a git range.
2. Nothing → the current branch: `git diff main...HEAD`.

For a PR number, fetch the diff via `gh pr diff <number>`; for a branch, `git diff main...<branch>`.

## Steps

1. **Adopt the persona.** Read `docs/agents/staff-engineer-agent.md` in full and operate as the
   Staff Engineer, Mode B. Its value system, Reference Corpus method, Evidence Standard,
   mutation-probe protocol, severity taxonomy (⛔ COMPOUNDING / 🟧 STRUCTURAL / 🟨 LEGIBILITY /
   🟦 TASTE), tone contract, and boundaries all apply verbatim.
2. **Load minimal context** per the agent file's Mode B requirements: the issue file(s) this
   branch implements (via `mcp__project-tools__get_issue` when the number is known), the plan file
   if present, and `docs/agents/reference/exemplars.md`.
3. **Run Mode B** exactly as specified in the agent file: whole diff, surrounding-module reads for
   context, **mutation-probe the diff's new/changed tests**, **drive the changed surfaces in a
   browser if the diff is user-facing** (including a coherence check against the neighbouring
   surfaces it didn't touch), scope-lock respected, no duplication of the other gates. Behaviour
   claims need run evidence; experience claims need a drive and a screenshot; taste claims need a
   verified exemplar; probes are reverted with Edit and confirmed clean before reporting.
4. **Deliver the Shadow Review report** (format in the agent file) with one of the three verdicts:
   - **LGTM**
   - **LGTM WITH NOTES** — offer to file 🟧 findings as follow-up issues via `create-issue`.
   - **DESIGN CONCERNS** — present the ⛔ findings and the fix-now vs file-and-ship trade-off to
     the human. Their call is final; record the outcome either way.

## Output

- The Shadow Review report (verdict, praise, findings table, ledger candidates, one question for
  the author).
- If the human accepts follow-ups: the issues created (numbers + files).
- When invoked from `finalize-pr`: a condensed "Staff review" block (verdict + finding one-liners)
  suitable for the PR body.

## Guardrails

- **Advisory only.** Never block or revert. Even DESIGN CONCERNS resolves by human decision.
- **Probes only, always reverted.** The one permitted edit is a mutation probe; restore it with
  Edit (never `git checkout -- <file>`) and confirm `git diff --stat` shows only the branch's own
  changes before reporting.
- **Design + test-truthfulness axes only.** Don't re-check standards compliance or re-audit DoD —
  those gates own their axes; cite them if relevant. Your distinct question about tests is not
  "do they pass" but "does passing mean anything".
- **Scope-lock:** concerns about pre-existing code the diff merely touches become ledger/follow-up
  candidates, not review findings — unless the diff actively deepens that debt.
- **No taste escalation:** 🟦 findings are recorded, never actioned or argued.
