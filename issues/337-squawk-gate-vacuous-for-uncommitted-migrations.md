# Issue #337: The squawk gate passes without reading anything when migrations are uncommitted

## Summary
Found by #335 and independently confirmed by the lead. `scripts/security-squawk.sh` selects its input with:

```sh
git diff --name-only --diff-filter=AM "$BASE"...HEAD   # BASE defaults to origin/main
```

That is a **committed-tree** diff. Migrations that exist only in the working tree — staged or unstaged — are invisible to it. When the resulting file list is empty the script prints `No changed migration files to lint — skipping squawk` and **exits 0**, which `just ci` reports as **PASS**.

So the sequence every agent and developer in this project actually follows — write a migration, run the gate, then commit — gets a **green squawk that inspected zero files**. #335 hit this exactly: `just run just ci squawk` PASSed while linting 14 unrelated historical migrations and **none of its own nine**. Forcing the real check via `SQUAWK_TARGET_DIR` immediately found **3 genuine violations** (`NOT VALID` + `VALIDATE` in one transaction ×3, and a `ban-drop-column` in a `down`).

This is the campaign's "structure-only gate masquerading as proof" class, in the one gate whose whole job is to stop a dangerous migration reaching production.

## User Stories
None — CI correctness. The validation path is a counterfactual: a known-bad uncommitted migration must fail the gate.

## Goal
`just ci` cannot report a green squawk that read no migrations. A gate with nothing to say must say so loudly enough that it is not mistaken for approval.

## Scope Check
One shell script plus its CI wiring. Single concern, well under the bar.

## Wiring
Router wiring: none. CI/gate surface only.

## Feature-Completeness Pre-Check
n/a — no user story. Acceptance is the counterfactual probe below.

## Technical Requirements
1. **Include working-tree migrations in the selection.** Union the committed diff with `git status --porcelain` (or `git diff --name-only HEAD` plus untracked) so staged and unstaged migrations are linted. A migration that exists on disk and has not yet been committed is precisely the one most worth checking.
2. **Stop conflating "nothing to lint" with "pass."** Distinguish the two states in the output and in `just ci`'s group summary — `SKIP (no migrations changed)` is honest; `PASS` is not. Decide deliberately whether a skip should be visually distinct from a pass in the roll-up (it should).
3. **Do not silently widen scope.** Linting *every* historical migration on every run would reintroduce the noise the `origin/main` diff was added to suppress — keep the diff, extend it to the working tree.
4. **Counterfactual test.** Prove the repair the way #330 proved the rate-limit fix: place a known-bad **uncommitted** migration (e.g. `NOT VALID` + `VALIDATE` in one transaction, or a non-concurrent `CREATE INDEX`), run the gate, and show it **fails** where the old form passed. Quote both transcripts.

## Reviewer Context
- ⚠️ **This bug means every squawk-green claimed in this campaign before a commit was vacuous.** Waves 0–4 each cite squawk; those citations are only meaningful where the migrations were committed *before* the gate ran. Wave 0's catch of `20260727204800_rekey_price_snapshots_to_edition.exs` was genuine because that migration was already committed. Re-check rather than assume, and say which waves were real.
- The `|| true` placement in the pipeline is load-bearing and was fixed once already (`set -euo pipefail` + `grep` no-match). Don't regress it — read the comment block at `scripts/security-squawk.sh:50-56` before editing.
- `SQUAWK_TARGET_DIR` already exists as the "lint everything in this dir" escape hatch — #335 used it to get a real answer. Consider whether the working-tree path should reuse it internally.
- Related gate-honesty work: #330 (fail-open rate-limit spec), #334 (enum coverage gate).
- Commit: agent commits are DENIED. Stage, one-line message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| CI/gate | yes | ❌ counterfactual: known-bad **uncommitted** migration → gate fails (old form passes) |
| CI/gate | yes | ❌ empty case reports SKIP, not PASS — asserted on the `just ci` summary line |
| Regression | yes | ❌ committed-migration path still works; historical noise still suppressed |
| Others | no | n/a |

## Definition of Done
- [ ] Working-tree migrations linted — evidence: counterfactual transcript, before and after
- [ ] Empty case reports SKIP not PASS — evidence: `just ci` summary output
- [ ] Historical-noise suppression preserved — evidence: run on a clean tree lints 0, not 105
- [ ] Campaign squawk citations re-checked and corrected where vacuous — evidence: per-wave statement
- [ ] `staff-review` verdict recorded below

## Dependencies
None — independent. Should land **before** any further migration-bearing wave so their squawk evidence means something. Found during #335 (Wave 4).

## Agent Assignment
devops/CI-leaning agent.

## Progress Notes
Filed 2026-07-30 by the lead from #335's finding #2. Independently confirmed by reading `scripts/security-squawk.sh:46-72`: the three-dot `"$BASE"...HEAD` diff cannot see the working tree, and the empty-list branch exits 0 with a "skipping" message that `just ci` renders as PASS.

**Additional constraint discovered by #339 (2026-07-30):** the `SQUAWK_TARGET_DIR` escape hatch — the workaround this issue currently recommends for getting a real answer — **scans the entire migration history, not a diff**. Running it reports **35 files with violations**, all `require-concurrent-index-creation` on 2026-03-05-era *table-creation* migrations (`CREATE UNIQUE INDEX users_idx ON op.users (email)` and kin), where a concurrent index is neither needed nor possible because the table is being created in the same migration.
This sharpens Technical Requirement 3: the fix must extend the **diff** to cover the working tree, **not** fall back to `SQUAWK_TARGET_DIR`'s scan-everything behaviour. If it does, the gate goes permanently red on 35 pre-existing, correct migrations and will be disabled or ignored within a week — which is the same failure as passing vacuously, arrived at from the other direction. Consider whether squawk needs a baseline/allowlist for the historical set as part of this work.

**Wave assignment (owner-approved 2026-07-31): Wave 11.**
Scheduled as item **11g**, explicitly sequenced **before 11d (prod deploy execution)**: carrying a migration-safety gate that inspects nothing into a production deploy is the exact failure this issue describes. Note also that no remaining campaign wave adds DB migrations (Wave 9's "hex migration" is CSS colour values), so nothing in Waves 5–10 is blocked on this.
