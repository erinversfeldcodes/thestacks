---
name: completion-audit
description: Adversarial "prove it is NOT done" pass, run before any issue/epic is marked complete, its PR opened, or the word "done" is used. Tries to break the done-claim — every Completion Bar item cited with a real evidence token, every deliverable driven live (real signal observed, not code-read), no structure-only gate standing in for a real one, no phantom #NNN, no stale audit / unchecked DoD on shipped work. Gates the orchestrator's Phase 3. Use whenever you or the user are about to declare something complete, when re-reviewing an epic that was previously called done, or when the user asks "is this actually done?".
---

# completion-audit

The pass that #236–240 and #248 lacked. #236–240 were marked `completed` with
baseline-❌ audit tables, unchecked "Meets the Completion Bar" DoDs, and no
live-exposure proof — nobody caught it until the owner asked "are these actually
done?". The whole #248 observability stack shipped structurally complete, tests
green, and **blank** — no metric ever reached the store. Both are the same failure:
**"done" declared on structure (code exists, tests pass, docs say ✅) instead of
proven on live behaviour, with nothing adversarial checking before the claim.**

This skill is that adversarial check. Its job is **not** to confirm the work is done
— it is to **try to prove it is NOT done**, and only clear it when it cannot. It
automates the "is this *really* done?" prompting the owner has had to do by hand. It
enforces `docs/agents/standards/completion-bar.md` and gates the orchestrator's
Phase 3.

## When to use — mandatory, before completion language
- Before marking any issue/epic complete, opening its PR, or saying "done".
- When re-reviewing an issue/epic previously called done (retro-apply the bar).
- When the user asks whether something is actually complete.
- After a `feature-completeness` + `test-audit` pass, as the final gate over the
  *whole* deliverable (those are per-story/per-cell; this is the epic-wide sweep).

## Posture: assume it is NOT done, then try to break each claim
Default to incomplete. For every "done" signal (a checked box, a ✅ cell, a merged
child, a green gate), ask **"what would make this a lie?"** and go look. A claim you
cannot back with a cited artifact is treated as **not done**, not as done-until-
disproven.

## The sweep — walk the deliverable and hunt each failure class

1. **Structure-marked-done but never driven live.** For every deliverable (user
   story AND infra/observability/platform/pipeline — completion-bar §1), demand the
   **real signal observed at the far end**: a user completed the journey through the
   real UI; a metric was *seen* to land in the store and render (not "the emit code
   exists"); an event row was written with the right payload. If the only proof is
   code-reading, a unit test, or a synthetic-data gate → **not done**. (The #248
   pipeline was inet6-broken and delivered nothing while every structural check was
   green.)

2. **Structure-only gates masquerading as proof (completion-bar §8).** For each gate
   cited as evidence, ask *what data did it run on*. Synthetic/mock/existence gates
   (dashboard-render-gate seeding its own series, a `≥1 series` smoke, a
   drift/`displayed ⊆ measured` check, "tests exist", "route wired") prove
   well-formedness only. Require **≥1 gate that exercised the real path with real
   data**. Flag any done-claim resting only on synthetic/structural gates.

3. **Evidence-less claims (completion-bar §9).** Every checked DoD box and ✅ audit
   cell must cite *how* it was proven — a verified test name, a command → captured
   output, a live-drive artifact, a real value observed, a PR/commit. A bare check is
   a claim; treat it as not done. (`scripts/hooks/lib/check-issue-evidence.sh` catches
   this at the edit boundary; this skill catches what the hook's heuristics miss and
   judges quality, not just presence.)

4. **Phantom / dangling references (completion-bar §10).** Every cited `#NNN` points
   to a real `issues/NNN-*.md` or an open GitHub issue/PR. A deferral hidden behind a
   fileless number is unfinished work dressed as "tracked". Deferrals become a real
   issue (`create-issue`) or an epic note.

5. **Stale tracking on shipped work (completion-bar §5).** A "baseline,
   pre-implementation" audit still sitting on merged code, an unchecked DoD on shipped
   work, a Feature-Completeness table without file:line + live-drive results — each is
   itself a completion defect. Regenerate to reality or it is not done.

6. **Named scope that was silently dropped.** Cross-check the issue/epic `## Summary`
   and story list against what actually shipped. A story quietly reclassified
   `n/a (see #NNN)`, a feature the epic *claims* but did not deliver, a phase that
   became a no-op — the Summary must be edited to match, or the feature built. (The
   #124/US-14.3.2 hole.)

7. **An axis deferred to a review that never ran.** `staff-review` covers design and
   test-truthfulness and explicitly defers standards, idiom, schema design and contract shape to the
   **stack reviewers** (`docs/agents/reviewers/`, routed per `AGENTS.md`). A deliverable carrying a
   staff-review and no stack review has had that second axis checked by **nobody** — and the
   automated gates will be green throughout, because they cover the mechanical half and none of the
   judgement. Check which stacks the diff touches and demand a recorded verdict for each; treat a
   missing one as **not done**, not as a nicety. An audit of one campaign found 42 of 43 issues
   staff-reviewed and **one** naming any stack reviewer, across 323 files.
   `just wave-status` now enforces this at campaign level via `domain_reviews`.

8. **Dangling reviewer findings & dirty logs (completion-bar §3/§4).** P2/P3 fixed or
   de-scoped to a tracked issue with rationale — never silently dropped. The live
   drive's logs read and clean (no swallowed 500s under a green suite).

9. **Integration, not just isolation (completion-bar §6).** For epics: `just verify`
   green on the integration branch after every merge, PE gate on the cumulative diff.

10. **Guard attestations and undischarged residue.** An absolute attestation ("NO further
   orphans", "all clean", "run_all.sh completes") cited as evidence is a claim to break:
   demand the planted-violation red run for any guard, and the caller for any runner — a
   guard once attested clean while structurally blind to the one violation that existed,
   and a runner was proven working while nothing invoked it. Separately, grep the
   deliverable's close-out notes for residue phrases ("remains", "follow-up-class",
   "not filed") with no follow-up issue or `plans/residue-ledger.md` row — undischarged
   residue is unfinished work dressed as done, same as a phantom `#NNN`.

## Output — a verdict, not a rubber stamp
- **PASS** only when every class above is clear, each with a cited artifact. Say what
  you drove live and what you observed.
- **FAIL** with a numbered punch list: each gap → which bar item, what is missing, and
  the concrete artifact/drive needed to clear it. A FAIL blocks completion language,
  PR-open, and the orchestrator's Phase 3.
- Prefer honest FAIL over a green that hides a deferral. "I could not drive X live, so
  it is at most 🟡" is a valid, required output.

## Scale
- Epic with many children → fan out one agent per child for classes 1–6, then judge
  integration (8–9) centrally. Spot-check cited artifacts (grep a sample of cited test
  strings / re-run one gate) — do not trust the citations blind.

## Related skills
- `feature-completeness` (is each named story *built* + driven live?) and `test-audit`
  (is each layer *tested*?) run first, per story/cell. **This skill is the epic-wide
  adversarial gate over the whole deliverable**, and it binds infra/observability
  deliverables that are not "user stories".
- `verify-and-followup` runs the gates and files residuals; this skill judges whether
  their evidence actually clears the bar.
- `create-issue` is where any gap that exceeds scope becomes a tracked follow-up.
