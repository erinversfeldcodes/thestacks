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
| CI/gate | yes | ✅ counterfactual: known-bad **uncommitted** migration → gate fails (old form passes) — `test/platform/squawk_worktree_selection_test.sh` cases 2/3/4, 27 assertions green |
| CI/gate | yes | ✅ empty case reports SKIP, not PASS — asserted on exit code 2 (case 1) and on the `just ci` roll-up |
| Regression | yes | ✅ committed-migration path still works (cases 5/6); historical noise still suppressed (cases 1b/6/8) |
| Mutation | yes | ✅ 4 probes (A working-tree legs, B exit-0 conflation, C create-table context, D `create_if_not_exists`) each turn the suite red — 10/1/2/2 assertions respectively |
| Others | no | n/a |

## Definition of Done
- [x] Working-tree migrations linted — evidence: counterfactual transcript, before and after (Progress Notes)
- [x] Empty case reports SKIP not PASS — evidence: `just ci` summary output (Progress Notes)
- [x] Historical-noise suppression preserved — evidence: clean tree lints the same 23 committed branch migrations as before, not 105
- [x] Campaign squawk citations re-checked and corrected where vacuous — evidence: per-wave statement below
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

---

### Implemented 2026-07-31

**Selection** — `scripts/security-squawk.sh` now unions three legs: the committed `"$BASE"...HEAD` diff (unchanged), `git diff --name-only --diff-filter=AM HEAD` (staged *and* unstaged), and `git ls-files --others --exclude-standard` (untracked). Deduped, filtered to the migrations path, and existence-checked so a path the committed diff names but the working tree has deleted is dropped. The working-tree legs are deliberately **not** diffed against the base, which is what keeps history out: a 2026-03 migration enters the set only if you actually touched it.

**SKIP ≠ PASS** — the script is now three-valued. `0` = migrations were inspected and are clean; `1` = violation; `2` = **nothing was inspected**. Exit 2 covers three cases that all used to exit 0: no changed migrations, squawk not installed, and — new — *changed migrations that contained no squawk-analysable SQL at all*. `scripts/ci.sh` renders 2 as a yellow `SKIP`, collects it, and downgrades the roll-up from `All checks passed.` to `No failures.` plus an explicit `Skipped (inspected nothing — not evidence of anything):` list. Both `.github/workflows/ci.yml` squawk steps translate exit 2 into a `::warning` annotation rather than a silent green — in those jobs the path filter has already said migrations changed, so a skip there is a contradiction worth seeing.

**The 35 historical violations (#339) — 23 of them were the gate's own false positive.** The extractor emitted a naked `CREATE INDEX users_idx ON op.users (email)` for a migration that *creates* `op.users` two lines earlier, and squawk, seeing no context, demanded `CONCURRENTLY`. `scripts/extract-migration-sql.py` now prefixes the statement stream with a column-less `CREATE TABLE <name> ();` for every table the migration itself creates; squawk tracks same-file table creation and correctly stops warning. Scan-all violations: **35 → 12**. No allowlist or baseline file was needed, and none was added — a suppression list would have hidden the 12 that are real. Those 12 are genuine, already-deployed hazards on live tables; they are not reachable by the diff-based gate and are reported as an out-of-scope finding rather than absorbed here.

**Missing base ref no longer means "lint everything."** The old fallback linted all 105 migrations when `origin/main` was unresolvable — the exact wall of red #339 warned would get the gate switched off. It now drops leg 1, keeps the working-tree legs, and says so on stderr. `E2E_SQUAWK_ALL=1` remains the deliberate door to linting history.

**Second hole found while auditing this issue's own evidence:** the DSL translator matched `create index` but **not** `create_if_not_exists index`, so the #219 blind spot was still wide open for the idempotent form. Wave 4's `20260730200500_create_email_lower_and_placement_edition_indexes.exs` — a migration whose entire job is building two indexes — extracted **zero** statements. Fixed; that branch's analysed count went 6 → 9 of 23.

**Counterfactual (before).** Probe migration `20260731999999_probe_known_bad_uncommitted.exs` (`NOT VALID` + `VALIDATE` in one transaction, plus a non-concurrent `CREATE INDEX`), **staged but uncommitted**:
```
$ bash scripts/security-squawk.sh HEAD
No changed migration files to lint — skipping squawk.
EXIT=0
$ bash scripts/ci.sh squawk
=== squawk: migration lint ===
PASS squawk: migration lint
All checks passed.
```

**Counterfactual (after).** Same file, same state:
```
$ bash scripts/security-squawk.sh HEAD
Linting 1 migration file(s) with squawk...
  .../20260731999999_probe_known_bad_uncommitted.exs
warning[constraint-missing-not-valid]: Using `NOT VALID` and `VALIDATE CONSTRAINT` in the same transaction ...
warning[require-concurrent-index-creation]: During normal index creation, table updates are blocked ...
ERROR: squawk found 1 file(s) with migration safety violations.
EXIT=1
$ bash scripts/ci.sh squawk        # probe untracked, default base
=== squawk: migration lint ===
FAIL squawk: migration lint
Failed checks:
  - squawk
```

**Empty case (after).** Clean tree, nothing changed:
```
=== squawk: migration lint ===
SKIP: no added or modified migration files (committed diff or working tree).
      squawk inspected 0 files. This is a SKIP, not a pass — nothing was checked.
SKIP squawk: migration lint — 0 migrations inspected (nothing was checked)
No failures.
Skipped (inspected nothing — not evidence of anything):
  - squawk: migration lint — 0 migrations inspected (nothing was checked)
```

**Clean tree still lints the diff, not history.** On this branch, before and after: **23** files selected (the branch's own committed migrations), **not 105**. What changed is honesty about depth — the success line now reads `squawk: clean — 9 of 23 changed migration file(s) carried analysable SQL and every statement passed`, where before it said `all migrations clean` while 17 of the 23 had been silently skipped.

**Regression suite.** `test/platform/squawk_worktree_selection_test.sh` (27 assertions, registered in `run_all.sh`) builds a throwaway git repo in `$TMPDIR` with copies of the scripts, so the commit graph is controlled and this repo is never touched. Its base branch deliberately carries a hazardous migration that must stay unlinted. Mutation-probed four ways; each probe reddens the assertions that name it.

### Per-wave squawk citation verdict (DoD item 4)

Branch topology matters: the campaign branches are a linear stack off `feat/staff-engineer`, so `origin/main..<branch>` for a later wave inherits every earlier wave's migrations. Each wave's *own* migrations were isolated with pairwise ranges.

| Wave | Own migrations | Verdict | Reason |
|------|---------------|---------|--------|
| **0** (#311) | 1 (`20260730090000`, commit `9dbfb9fa`) | **REAL** | Citation is explicitly a post-commit re-run ("squawk re-verified green after 9dbfb9fa"). Its catch of `20260727204800_rekey_price_snapshots_to_edition.exs` is confirmed genuine: added by `7258a0f6` on 2026-07-27, an ancestor commit, so it was inside the committed diff. Nuance — the migration it caught was an **ancestor's**, not Wave 0's own; Wave 0's own new migration was covered by the same re-run. |
| **1** | — | **struck** | Wave 1 (GDPR completion) was struck by the owner on 2026-07-30. |
| **2** (#312) | 0 | **N/A** | No migrations added. "squawk clean" is not false, but contains zero Wave 2 content. Qualified in place. |
| **3** (#313) | 0 | **N/A** | Same. Qualified in place. |
| **4** (#314) — child #335 | 9 | **VACUOUS** | #335 ran `just run just ci squawk` while its nine migrations were uncommitted; the gate linted 14 inherited files and none of its own. Already self-flagged — the DoD box was never ticked. This is the finding that produced this issue. |
| **4** (#314) — wave level | 9 (all in `9e69e5ce`) | **REAL, but the count was wrong** | The re-run was post-commit and did select all 9. The claim "linted 8 of the 9" was wrong twice: only **6** yielded analysable SQL, and one of the 3 silent ones was the pure-index migration whose DSL form the extractor could not match. Corrected in #314 line 52; with the `create_if_not_exists` fix the same nine now analyse 9 of 9. |
| **5** (#315) | 0 | **N/A** | No squawk citation exists; its gate box cites `just verify`, which does not run squawk. |
| **follow-ups A** | 0 | **N/A** | No migrations, no squawk-green claim. |

Net: exactly **one** citation was outright vacuous (#335's), and it was already flagged. One (#314's) was real but overstated its depth, and is corrected. The rest cite a squawk that read only inherited files — not false, but not evidence about the wave that cited it; #312 and #313 now say so.

### Out-of-scope findings (not fixed here)

1. **12 genuine hazards in already-deployed migration history.** With the false positives removed, a full scan still reports 12 files: `require-concurrent-index-creation` ×9 (non-concurrent index builds on live tables — `20260320000001..4`, `20260321000001`, `20260309000001`, `20260307000001`), `require-concurrent-index-deletion` ×2, plus one each of `ban-drop-column`, `changing-column-type`, `adding-foreign-key-constraint`, `adding-not-nullable-field`, `constraint-missing-not-valid`, `require-enum-value-ordering`. All shipped; none reachable by the diff-based gate. Worth a triage issue, not a silent allowlist.
2. **`drop index` / `drop_if_exists index` DSL is not translated at all.** The extractor synthesises `CREATE INDEX` from the DSL but nothing for drops, so a non-concurrent index *drop* written in the DSL is invisible to `require-concurrent-index-deletion` exactly the way non-concurrent creates used to be. Same defect class as #219 and as the `create_if_not_exists` hole found here.
3. **`scripts/security-squawk-test-wrapper.sh` had drifted from the gate** — it excluded 2 rules where the gate excluded 3 (`ban-concurrent-index-creation-in-transaction`), despite both files' comments asserting they can never disagree. Aligned here, but the guarantee is still by convention: nothing tests that the two exclude lists match.
4. **Two pre-existing shellcheck warnings in `scripts/ci.sh`** (SC2164 at line 27, SC2034 at line 272) — untouched, not introduced here.
5. **`test/platform/e2e_warmup_guard_test.sh` does not terminate in reasonable time.** It ran for 15+ minutes without producing a tally during this issue's `run_all.sh` verification. It references nothing this change touched. Probable cause: `wait_for_health` in `scripts/test-e2e.sh` deliberately has *no* `sleep` in its poll loop ("curl itself has a 2s timeout"), but the suite replaces `curl` with a shell function that returns instantly — turning the deadline loop into a hot spin. Pre-existing; the fourteen suites ahead of it in `run_all.sh`, including all four migration suites, are green.

**staff-review verdict: LGTM** (2026-07-31, lead, Mode B on bf03f214). The strongest child of this campaign. Praise: (a) it **refused the allowlist** the issue floated for the 35 historical violations, on the grounds that "one would have hidden the real ones" — and then found **23 of the 35 were the gate's own false positive**: the extractor emitted a naked `CREATE INDEX ... ON op.users` for a migration that *creates* `op.users` two lines earlier. Prefixing a column-less `CREATE TABLE <name> ();` per table created in the same file lets squawk track same-file creation and stop warning. **35 → 12**, and the 12 that remain are genuine already-deployed hazards on live tables, reported rather than absorbed; (b) **SKIP ≠ PASS is a real third state** — exit 2 covering no-changed-migrations, squawk-absent, *and* the new "changed migrations contained no analysable SQL", rendered yellow by `ci.sh`, collected into an explicit skip list, and downgrading `All checks passed.` to `No failures.`. CI translates it into a `::warning` rather than a green; (c) the working-tree legs are deliberately **not** diffed against the base — that is precisely what keeps 105 historical migrations out while still seeing staged and untracked ones; (d) the new test builds a throwaway git repo in `$TMPDIR` whose base branch **deliberately carries a hazardous migration that must stay unlinted**, so the "don't widen to history" property is asserted rather than assumed; (e) five mutation probes, including one that restores the pre-#337 selection and reddens 10 assertions.
**A second gate hole found while auditing this issue's own evidence:** the DSL translator matched `create index` but **not `create_if_not_exists index`**, so the #219 blind spot was wide open for the idempotent form — the form this project uses for concurrent indexes. One-token fix plus a regression case; this branch's analysed depth went **6 → 9 of 23**.
**⚠️ It corrected the LEAD's own Wave 4 claim, and it was right.** I reported at the Wave 4 close that "squawk PASS and non-vacuous — it linted 8 of the 9 new migrations". Wrong twice: selecting a file is not analysing it, only **6** of the 9 yielded analysable SQL, and one of the three silent ones was `20260730200500_create_email_lower_and_placement_edition_indexes.exs` — **a migration whose entire job is building two indexes**, i.e. exactly what squawk exists to check. Lead-verified by running the pre-merge extractor against that file (**zero output**) and the post-merge one (**both `CREATE INDEX CONCURRENTLY IF NOT EXISTS` statements**). #314's record is corrected in place.
**Per-wave verdict on this campaign's squawk citations:** Wave 0 **REAL** (`20260727204800…` was an ancestor commit, inside the committed diff — with the nuance that the migration it caught was an ancestor's, not Wave 0's own); Waves 2, 3, 5 and follow-ups A **N/A** (zero own migrations — "squawk clean" was true but carried no content of theirs, now stated in #312/#313); Wave 4 child **#335 VACUOUS** — the one outright bad citation, and the finding that produced this issue; Wave 4 wave-level **REAL but miscounted** (above).
**Findings carried forward:** (1) `drop index` / `drop_if_exists index` DSL is **not translated at all**, so a non-concurrent index *drop* is invisible exactly the way creates used to be — same class, not fixed; (2) **12 genuine hazards in deployed migration history** (9× non-concurrent index creation on live tables, 2× deletion, plus `ban-drop-column`, `changing-column-type`, `adding-foreign-key-constraint`, `adding-not-nullable-field`, `constraint-missing-not-valid`, `require-enum-value-ordering`) — worth a triage issue; (3) `security-squawk-test-wrapper.sh` had **drifted** from the gate (2 excluded rules vs 3) despite both files' comments asserting they cannot disagree — aligned, but nothing tests that they match; (4) ⚠️ **`test/platform/e2e_warmup_guard_test.sh` does not terminate** — ran 15+ minutes with no tally; likely a hot spin because the suite replaces `curl` with an instant shell function while `wait_for_health` deliberately has no `sleep` ("curl has a 2s timeout"). Unrelated to this diff; the 14 suites ahead of it, including all four migration suites, are green.
Clean-tree behaviour: **23 files selected, not 105** — identical selection to before, now honest about depth (`squawk: clean — 9 of 23 changed migration file(s) carried analysable SQL`, where it previously said "all migrations clean" while silently skipping 14).
