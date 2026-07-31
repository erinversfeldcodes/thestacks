# Issue #354: The proto drift check fails the gate for local staleness it should just fix

## Summary
Hit twice during this campaign — Wave 4 (`gen/proto/enums.ex`) and Wave 5 (`gen/proto/vision.ex`, `enums.ex`, `apps/vision/app/proto/gen/vision.py`). After merging a child branch that touched a `.proto` file, the main checkout's **gitignored** generated artefacts are stale. `scripts/lint-proto.sh` reports `DRIFT: … is out of date`, and the failure cascades: `proto: lint` fails, and so do `elixir: test` and `python: test`, because they compile and import against the stale generated code.

Wave 5's gate reported **three** failing groups. All three were this. Zero were real.

```
FAIL elixir: test      → compiled against stale gen/proto/enums.ex
FAIL python: test      → tests/test_proto_drift.py, same cause
FAIL proto: lint       → DRIFT: apps/vision/app/proto/gen/vision.py is out of date
```
After running the four generators: elixir **3339/0** (coverage 81.7%), python **134 passed**, `lint-proto.sh` **exit 0**, and `git status` clean — because **every drifted file was gitignored**.

## The insight
**Drift in a gitignored generated file can only ever be local.** In CI the artefacts are generated from scratch on every run, so they cannot be stale — the check is only ever *meaningful* for **tracked** files, where a committed generated file has diverged from its source. For gitignored ones the correct response is to regenerate, not to fail.

So the check currently conflates two different situations and reports the harmless one as a build failure, which is the mirror image of #337 (squawk reporting a vacuous pass as PASS). Both are the same underlying defect: **a gate whose output does not distinguish the states it can be in.**

The cost is not just noise. A gate that cries wolf on a clean tree trains people — and agents — to re-run it and move on, which is precisely how a real drift would get waved through.

## User Stories
None — CI/tooling correctness. Validated by the counterfactual below.

## Scope Check
One shell script plus, optionally, a convenience target. Single concern.

## Wiring
Router wiring: none.

## Technical Requirements
1. **Distinguish tracked from gitignored** in the drift check. `git check-ignore` (or `git ls-files --error-unmatch`) answers it directly — the project convention is to verify tracked status with git, not by reading `.gitignore` (agents get this wrong and it fails silently).
2. **Gitignored + stale → regenerate and continue**, reporting what it regenerated. **Tracked + drifted → fail**, as today. Decide whether regeneration should be automatic or gated behind a flag; automatic is defensible here because the file is not under version control and the generator is the only writer.
3. **Do not weaken the real check.** A tracked generated file that has drifted from its `.proto` source must still fail the build. That is the case this check exists for.
4. **Counterfactual acceptance test**, the way #330 proved the rate-limit repair: (a) stale gitignored artefact → gate green, artefact regenerated, message says so; (b) drifted *tracked* artefact → gate still red. Quote both transcripts.
5. **Consider the convenience target.** `just bootstrap-worktree` (added 2026-07-31) solves this for worktrees and deliberately no-ops in the main checkout. The main checkout has no equivalent "you just merged proto changes, regenerate" step — that gap is what produced both incidents. A `just regen-proto` alias, or making the main-checkout path regenerate rather than no-op, would close it. State which you chose and why.

## Reviewer Context
- ⚠️ **FIVE codegen targets, not two** — `mix proto.sync` and `scripts/gen-elixir-proto.sh` are *different*; `scripts/lint-proto.sh` checks all five. An Ecto-only regen leaves the wire structs adrift, which has bitten this project twice independently of this issue.
- ⚠️ Do not "fix" this by having `just ci` regenerate unconditionally before checking — that makes the drift check vacuous for tracked files too, turning a real gate into a green light. The distinction must be on tracked status, not on ordering.
- Related gate-truthfulness work: **#337** (squawk passes without reading anything), **#334** (the enum coverage gate). This is the third gate in this campaign found reporting something other than what it means.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| CI/gate | yes | ❌ stale gitignored artefact → regenerated, gate green, message emitted |
| CI/gate | yes | ❌ drifted **tracked** artefact → gate still red (the check must not be weakened) |
| Regression | yes | ❌ a fresh clone/CI run still passes all five targets |
| Others | no | n/a |

## Definition of Done
- [x] Tracked vs gitignored distinguished via git, not `.gitignore` parsing — evidence: `scripts/generated-file-class.sh` (`git ls-files --error-unmatch`, then `git check-ignore`)
- [x] Gitignored staleness regenerates and reports; tracked drift still fails — evidence: both counterfactual transcripts (Progress Notes)
- [x] Main-checkout regeneration gap closed, with the chosen approach stated — evidence: `just regen-proto` + `bootstrap-worktree.sh` main-checkout path
- [ ] `staff-review` verdict recorded below

## Dependencies
None. Related to **#337** (same class). Needs an owner wave assignment — worth landing before another migration- or proto-bearing wave, since it costs a full gate re-run each time it fires.

## Progress Notes
Filed 2026-07-31 by the lead after Wave 5's gate reported three failures that were all one cause. Wave 4 hit the identical thing with `gen/proto/enums.ex`. Every drifted file in both incidents was gitignored, confirmed with `git ls-files --error-unmatch`.

**Implemented 2026-07-31.** The policy lives in one place — `scripts/generated-file-class.sh`, which prints `tracked` / `ignored` / `untracked` and is consulted by all three drift checks (`gen_python_proto.py --check`, `gen-elm-proto.sh --check`, `Mix.Tasks.ProtoSync.DriftChecker`). It is only reached once drift is already known, so the clean path costs nothing. `untracked` fails closed: an artefact that cannot be proven disposable is treated like a tracked one.

Counterfactual (a) — the exact Wave 5 trio, made stale, then `scripts/lint-proto.sh`:

```
### STEP 2 — classify each (git, not .gitignore)
  apps/core/lib/stacks/gen/proto/enums.ex        -> ignored
  apps/core/lib/stacks/gen/proto/vision.ex       -> ignored
  apps/vision/app/proto/gen/vision.py            -> ignored

### STEP 3 — run the gate
REGENERATED: apps/vision/app/proto/gen/vision.py is out of date — gitignored, so this can only be local staleness; regenerated from proto and continuing.
REGENERATED: apps/core/lib/stacks/gen/proto/vision.ex is out of date — gitignored, so this can only be local staleness; regenerated from proto and continuing.
REGENERATED: apps/core/lib/stacks/gen/proto/enums.ex is out of date — gitignored, so this can only be local staleness; regenerated from proto and continuing.
### GATE EXIT: 0
```

Counterfactual (b) — the *same file* with the *same drift*, the only variable changed being that git now tracks it:

```
### B1 — the SAME artefact as counterfactual (a), now tracked
  classified: tracked
DRIFT: apps/core/lib/stacks/gen/proto/enums.ex is out of date — run: scripts/gen-elixir-proto.sh
### GATE EXIT: 1   (must be 1)
  STALE MARKER still present (NOT silently regenerated): 1
```

Main-checkout gap: chose **`just regen-proto`** (`scripts/regen-proto.sh`) as a first-class recipe, and made `bootstrap-worktree.sh`'s main-checkout branch `exec` it instead of exiting 0 with advice — so the one command an agent is already told to run is correct in both places. `proto-sync-all` and `bootstrap-worktree.sh` now both delegate to it, which is how the missing fifth target was found: `proto-sync-all` ran four of five, omitting `gen-python-proto.sh` — exactly the artefact Wave 5 tripped over.
