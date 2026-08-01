# Issue #345: W5 child — Extract `Stacks.Books.ISBN` and `Stacks.Uploads` so `books.ex`'s contract is statable

## Summary
Child of epic #315, Level 4 — the wave's last child, deliberately sequenced after #341/#342/#343/#344 so it moves **settled** code. `apps/core/lib/stacks/books.ex` is **1,698 lines with 41 public functions**, and they are not one domain: work/edition CRUD, the upload-and-image lifecycle, catalogue listing and search, author resolution, four changesets, and pure ISBN arithmetic all live in one module. Nobody can state what `Books` is responsible for, which is why drift kept accumulating inside it — the two-create-paths defect #341 fixed, and the identifier drops #341 and #346 found, both grew in that fog.

## User Stories
None — structural. Validated by "behaviour is unchanged", which is a stronger claim than it sounds and is the whole test strategy below.

## Goal
`Books` is about works and editions. Pure ISBN arithmetic and the upload/image lifecycle live in modules named after what they do, and their contracts can be read without reading 1,700 lines.

## Scope Check
**A pure move plus one deletion. No behaviour change whatsoever.** If the move seems to require a behaviour change, that is a scope surprise — stop and report rather than absorbing it.

## Wiring
Router wiring: none. Internal module boundaries only; controllers and workers change only which module they call.

## Feature-Completeness Pre-Check
n/a — no user story, no user-visible change. If anything becomes user-visible, the move was not pure.

## Technical Requirements
1. **`Stacks.Books.ISBN`** — the pure arithmetic, currently around `books.ex:1590-1698`: `valid_isbn_checksum?/1`, `canonical_isbn13/1` and their privates (`isbn13_valid?/1`, `isbn10_valid?/1`, `valid_isbn10?/1`, `isbn10_check_digit_ok?/1`, `to_isbn13/1`). ⚠️ **Locate them by name, not by line** — three children rewrote this file during Wave 5. These functions take strings and return values; they touch no repo and no context, which is exactly why they should not be buried in one.
2. **`Stacks.Uploads`** — the image lifecycle, currently around `books.ex:474-745`: `store_upload/2`, `store_upload_bytes/2`, `init_upload/2`, `commit_upload/2`, `reject_image/2`, `upload_and_identify/3`, plus `uploaded_image_changeset/2` and the image-status/`@min_image_bytes` module attributes they depend on. ⚠️ **Check the boundary before moving**: CLAUDE.md's convention is "contexts as bounded domains". If a function straddles books and uploads, say so and choose deliberately rather than splitting it in half.
3. **Delete `Books.identify/2`.** #344 established it is dead: no route, worker or context calls it — only `books_test.exs`. Its tests go with it, **with a coverage note** naming what still covers anything they were incidentally protecting (the #330 precedent). ⚠️ Verify the dead-code claim yourself before deleting; do not take it on trust.
4. **Update all call sites.** Prefer explicit calls or aliases over delegation shims — a `defdelegate` left behind means `books.ex` still names everything and the contract is no clearer, which is the entire point of the issue. If you keep any shim, justify it.

## Reviewer Context
- BOOTSTRAP: **`just bootstrap-worktree`** from inside your worktree (new as of 2026-07-31 — it copies `.env`, seeds the generated `gen/` tree, copies the esbuild `index.html`, runs `deps.get`, generates all five codegen targets and verifies no drift). Then `git merge --ff-only feat/campaign-w5-315` — **LOCAL, UNPUSHED**; no `git fetch`, no `origin/`.
- **NEVER bare `mix`** — `just run mix …`. **`caffeinate -i`** for long suites. **NEVER `git checkout`** to revert a probe — Edit, then `grep -c`. **Stage incrementally.**
- ⚠️ **`apps/core/lib/stacks/gen/` is proto-generated — never hand-edit it.** If a move appears to need a generated file changed, the change belongs in `proto/persisted.exs` plus `mix proto.sync`, and that is a scope surprise for this issue.
- ⚠️ **GDPR:** `GDPR.Deletion` and `GDPR.Export` reach image rows. Moving the upload functions must not move them out of erasure's reach. **Run the `gdpr-review` skill** and cite the verdict; the schema-guard test must stay green.
- ⚠️ `Stacks.Moderation`, `IdentifyBookJob`, `UploadController` and `EnrichBookJob` are the heaviest callers — #342 and #344 changed all of them this wave. Re-read them before moving anything they call.
- Dialyzer is currently at **0 errors**; keep it there. `books.ex` carries a `@dialyzer :no_opaque` for an `Ecto.Multi` false positive — decide whether the extracted modules need it rather than copying it reflexively.
- Commit: agent commits are DENIED. Stage; ONE-LINE message (no body/trailers) to `/private/tmp/claude-501/-Users-erinversfeld-thestacks/78bc6659-34d4-45c2-b5b7-9a0337db2154/scratchpad/commit-msg-345.txt`. NEVER push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Regression | yes | ❌ **the acceptance instrument**: identical suite counts before and after, with **zero changed assertions** — only module references may differ |
| GDPR | yes | ❌ `gdpr-review` verdict cited; erasure still reaches image rows |
| Static | yes | ❌ dialyzer stays at 0 errors; credo `--strict` clean |
| Coverage | yes | ❌ coverage note for the deleted `identify/2` tests |
| Others | no | n/a |

## Definition of Done
- [ ] `Stacks.Books.ISBN` extracted; no repo/context dependency — evidence: the module + `grep` showing no `Repo` reference
- [ ] `Stacks.Uploads` extracted with its boundary stated — evidence: diff + the boundary decision
- [ ] `identify/2` deleted after independently verifying it is dead — evidence: the verification + coverage note
- [ ] No delegation shims left in `books.ex`, or each justified — evidence: diff
- [ ] **Zero changed test assertions**; identical counts before/after — evidence: both counts + `git diff` character of the test changes
- [ ] `gdpr-review` PASS — evidence: verdict
- [ ] dialyzer 0, credo clean, suites green — evidence: outputs
- [ ] `staff-review` verdict recorded below

## Dependencies
Epic #315. **Depends on #341, #342, #343, #344** — all four rewrote code inside `books.ex`; extracting before they landed would have moved a moving target. Level 4, last in the wave.

## Agent Assignment
elixir-agent.

## Progress Notes
Filed 2026-07-31 (Wave 5, Level 4). Lead pre-check: `books.ex` is 1,698 lines / 41 public functions; the ISBN arithmetic sits at ~1590-1698 and the upload lifecycle at ~474-745, but all line numbers are approximate after this wave's four children.
Built in worktree; commit 95713f86; merged into `feat/campaign-w5-315`. 19 files, +726/−640.
**staff-review verdict: LGTM** (2026-07-31, Mode B on 95713f86). Praise: (a) **it proved purity mechanically rather than asserting it** — scripted a match of every `-` line in the test diff against every `+` line after applying only a module-rename map, and reported **0 unexplained lines**; separately verified 149 moved production lines byte-identical by diffing the extracted block against the new module. That is the right instrument for a refactor whose entire claim is "nothing changed"; (b) suite went **3342 → 3339**, and the −3 is exactly the three deleted `identify/2` tests — a number that reconciles rather than merely looks fine; (c) **no `defdelegate` anywhere** — callers were repointed, so `books.ex` stopped naming everything, which was the point of the issue; (d) it broke a **dependency cycle** nobody had named: `ISBNResolver → Books → ISBNResolver` is gone, and `TitleSearchCache` and `NormaliseEditionIsbn10` now depend on nothing in the `Books` context at all; (e) it stated its boundary decision in the moduledoc — `Uploads` owns the image row and its bytes, not the `UploadedImage` schema (proto-generated, stays under `Books`) and not what the pipeline decides — and named `upload_and_identify/3` as the one straddler with a reason for where it landed; (f) it **flagged its own single non-mechanical change**: three `Logger` prefixes `"Books.reject_image:"` → `"Uploads.reject_image:"`, noting no test or metric reads them and that shipping a stale module name in a log line would be a knowing defect. Declaring the one exception is what makes the purity claim credible.
**`identify/2` deletion independently justified** — it re-verified the dead-code claim itself rather than trusting #344 (no route, no controller action, no worker or context caller; only `books_test.exs`) and wrote a coverage note naming what still covers the `extract_isbn` seam, the multi-ISBN fan-out and the resolver-miss fallback.
`books.ex`: **1,698 → 1,233 lines, 41 → 30 public functions.** `Stacks.Books.ISBN` verified pure (zero `Repo`/`Ecto`/`alias` matches). Dialyzer **0 errors** — and it checked whether the new modules needed `@dialyzer :no_opaque` rather than copying it reflexively (they do not; the `Ecto.Multi` false positive stays with `books.ex`). credo `--strict` clean after fixing 5 it introduced, with the full suite re-run because the fixes touched test files.
**⚠️ The GDPR review is the most valuable thing in this diff, and it is not about this diff.** The move itself is GDPR-neutral. But asking the erasure question *against a real database* rather than reading code, it found `GDPR.Deletion.delete_user_data/1` returns `:ok` while the user's `uploaded_images` row survives **with their `user_id` intact** — and the schema-guard stays green throughout. **Lead independently confirmed the mechanism:** `op.uploaded_images` has exactly two FKs (`book_id`, `book_edition_id`) and **none to `op.users`**, so the guard — which enumerates FKs *referencing* `op.users` — never inspects it. Filed as **#353**, correctly not absorbed, with the probe deleted and the schema-guard suite left green (13/0).
**Generalisation added to #353 by the lead:** the guard is strong against the *wrong-delete-behaviour* defect — verified in #335's review, where weakening one FK to `NO ACTION` reddened it — and **structurally blind to a column that should be an FK and is not**. A guard that audits the edges that exist cannot see a missing edge. The guard extension is therefore the load-bearing half of #353, not a tidy-up.
**Findings carried forward:** (1) `store_upload/2` and `upload_and_identify/3` have **no production callers** (only `commit_upload/2` calls the latter internally), yet 18 tests drive `store_upload/2` — a deletion candidate for a later sweep; (2) `docs/user_stories/US-1.1.7-bulk-upload.md:71` claims a `StacksWeb.UploadController.identify/2` that never existed — pre-existing doc drift, correctly left alone.
