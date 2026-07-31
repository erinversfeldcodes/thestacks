# Issue #343: W5 child — Wire `POST /api/books/confirm` into the manual path and delete the DIY flow

## Summary
Child of epic #315, Level 2. **This is the wave's headline and the campaign's dominant defect class in its purest form.** `Books.confirm/2` (`books.ex:974`) already implements duplicate detection, `find_same_work` merging (Jaro-Winkler > 0.8), and atomic create-and-place. It has **zero frontend and zero E2E callers.** Meanwhile the manual ISBN path calls only `find_existing` (`book_controller.ex:246`), so a **valid ISBN that is not already in the catalogue returns 404 "check the number"** — driven live 2026-07-30. The feature is built; nothing reaches it.

## User Stories
US-1.1.5 (manual entry), US-1.1.6 (duplicate awareness), US-1.1.8 (same-work merge).

## Goal
Manual ISBN entry can add a book the catalogue has never seen. A second ISBN of a work already present offers a merge instead of silently minting a second work. The reader is *informed* about duplicates, never blocked.

## Scope Check
One Elm page + one Api client function + deletion of the DIY hops. No new endpoint — the endpoint already exists and is the whole point. Under the bar.

## Wiring
Router wiring: **uses the existing `POST /api/books/confirm`**; deletes the two superseded DIY hops from the client. User-facing on completion.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops | Live-drive result | Verdict | Resolution |
|-----------|------------------|-------------------|---------|------------|
| US-1.1.5 add a NEW book via manual ISBN | `find_existing` only — no external resolve | **404 "check the number"** on a valid new ISBN (driven 2026-07-30) | ❌ | build in-scope |
| US-1.1.8 same-work merge prompt | `find_same_work` called only by the dead `confirm/2` | two "Name of the Rose" works live in search | ❌ | build in-scope |

## Technical Requirements
1. **`Api.elm` gains the confirm client function**; `Page.Upload.elm`'s manual path calls `POST /api/books/confirm` instead of the DIY `lookupByIsbn` → `placeBook` sequence.
2. **Delete the DIY flow.** Do not leave it beside the new one — a second path is how the drift #341 just fixed got created in the first place. If something still needs a hop the new flow lacks, that is a finding to report, not a reason to keep both.
3. **Surface `confirm/2`'s outcomes in the UI.** It returns duplicate/merge/existing/created cases (arity changed to 5-tuple in #333). Duplicate notices are **informational and must never block** — owner ruling 2026-07-30, already honoured on the photo path and by the multi-shelf notice. The merge prompt follows US-1.1.8 copy.
4. **Do not re-implement matching client-side.** `confirm/2` calls `find_same_work` server-side; the prompt consumes its result.

## Reviewer Context
- BOOTSTRAP (worktree): `git merge --ff-only feat/campaign-w5-315` FIRST — **LOCAL, UNPUSHED**; no `git fetch`, no `origin/`. It contains **#341**, which you build on. Copy `/Users/erinversfeld/thestacks/.env`; regenerate proto artifacts (rsync `apps/core/lib/stacks/gen/` from the main checkout first if `core` won't compile); copy `apps/core/assets/index.html` → `apps/core/priv/static/index.html` if `PageControllerTest` fails. Run elm-test via the MAIN checkout's binary with `proto/gen/elm` copied in.
- **NEVER bare `mix`** — `just run mix …`. **`caffeinate -i`** for long runs. **NEVER `git checkout`** to revert a probe — Edit, then `grep -c`.
- ⚠️ **W-11-class regression guard (the acceptance test):** the wired manual path's test must use a **checksum-valid ISBN ABSENT from the DB** with a **seamed resolver mock**, and must be **red against today's code first**. An ISBN already in the DB tests `find_existing`, not the new wiring — it would pass before your change and prove nothing.
- ⚠️ **The ISBN CHECK constraint is live (#335).** A test ISBN with a bad check digit is now rejected by the *database*, not just by validation. Use checksum-valid values; `apps/core/test/stacks/data_correction_test.exs` has verified examples.
- #341 unified the create paths — there is exactly one `Multi.insert(:book, …)`. `confirm/2` routes through it.
- ⚠️ Elm module exposing: pages with tests must expose `Msg(..)`, not bare `Msg` (`Page.Upload` also needs `UploadResult(..)`). `elm-review --fix` will narrow it back if no test consumes it — land the exposure together with its consuming test.
- ⚠️ Run `bash scripts/check-orphan-classes.sh` before reporting: any new CSS class with no rule is its own defect class (398 such orphans already exist; add zero).
- Commit: agent commits are DENIED. Stage; ONE-LINE message (no body/trailers) to `/private/tmp/claude-501/-Users-erinversfeld-thestacks/78bc6659-34d4-45c2-b5b7-9a0337db2154/scratchpad/commit-msg-343.txt`. NEVER push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| API calls | yes | ❌ manual-entry of a NEW valid ISBN → 201 via confirm (seamed resolver), red against today's code |
| API calls | yes | ❌ second ISBN of an existing work → merge outcome, not a second work |
| Elm | yes | ❌ program test drives the manual path on the new flow; duplicate notice appears and does NOT block |
| Elm | yes | ❌ the DIY hops are gone — assert by absence of the old Msg/effect, not by a comment |
| Others | no | n/a |

## Definition of Done
- [ ] Manual path calls `confirm`; DIY flow deleted — evidence: diff + `grep` showing no second path
- [ ] NEW-ISBN test red-then-green with a seamed resolver — evidence: probe transcript
- [ ] Merge prompt on a same-work second ISBN — evidence: test name
- [ ] Duplicate notice informs without blocking — evidence: program test asserting the flow still advances
- [ ] `check-orphan-classes.sh` shows zero new orphans — evidence: output
- [ ] Suites green under `caffeinate` — evidence: counts
- [ ] `staff-review` verdict recorded below

## Dependencies
Epic #315. **Depends on #341** (wiring the verb must not spread the create drift). Level 2. **Precedes #344** (which also edits `Page/Upload.elm` — serialised deliberately to avoid a conflict by construction).

## Agent Assignment
elm-agent + elixir-agent.

## Progress Notes
Filed 2026-07-31 (Wave 5, Level 2 unblocked by #341).
Built in worktree; commit aae87217; merged into `feat/campaign-w5-315`. 8 files, +1070/−193.
**staff-review verdict: LGTM** (2026-07-31, Mode B on aae87217). Praise: (a) the red-then-green transcript's failure text **names the defect itself** — `Expected HTTP request (POST /api/books/confirm) … but no such requests were made. The following requests were made: GET /api/books/isbn/9780156453806` — the old path went to `find_existing` only; (b) it was **honest about where the red could live**: the API contract was already complete and green-tested since #330, so no server-side test *could* be red because nothing server-side was broken — the defect was purely the missing caller. It said so and strengthened the Elixir tests instead of manufacturing a fake red one; (c) it moved shelf selection *before* confirm with a stated reason — `confirm/2` creates and places in one transaction, so asking afterwards could only place on a shelf the reader never picked or file the book twice; (d) `:already_placed` renders *"is already on your Wish List"* rather than a false *"added to"* — the structurally-valid-but-false-payload class avoided without being told; (e) it found and fixed an **unasked-for gap on the photo path**: `GET /api/books/:id` has carried `placements` since #333, but Upload read only the book, so the verify step — the last moment before a second copy — said nothing; (f) it strengthened two Elixir tests in place: the 409 test now asserts **no second work minted and no edition attached** (W-13 in regression form, where the old test proved only that the endpoint said "merge"), and the 201 test asserts the placement actually landed.
**DIY flow verified gone by independent grep:** `lookupByIsbn|IsbnLookupResult|isbnLookupState` → **0 matches** across `frontend/src`, `frontend/tests`, `e2e/tests`.
**Lead independent probe → a finding the child could not have been expected to catch.** I probed the riskiest new behaviour: does the reader's chosen shelf actually reach the server? Hardcoded `Api.confirmBook`'s body to `Encode.string "wishlist"` — i.e. pick Antilibrary, file to Wish List. **The suite stayed fully green: 1353 passed, 0 failed.** The good test that exists (`manual_isbn_shelf_choice`, asserting `antilibrary`) validates the *translator's* encoder in `TestHelpers.uploadEffects`, not `Api.confirmBook`, so the production encoder has no test at all. ⚠️ **This is NOT a regression by #343** — all five requests in that translator are hand-built; the child followed the file's existing convention. Filed as **#347** with the probe transcript; it is the request-side twin of the decoder-side mirrors #328 removed in Wave 3 (where one mirror had *already* diverged from production). Probe reverted via Edit; `git status` clean, `grep -c` → 1.
Gates: `check-orphan-classes.sh` **0 new orphans** (88 verified test hooks, unchanged baseline); `check-css.sh` 729 rules / 0 problems / 0 collisions; `lint-elm.sh` green. Suites: elm **1353/0** (+9), elixir **3302/0**.
**Findings carried forward:** (1) ⚠️ **the "We think this is…" preview step is gone from the manual path** — there is no resolve-without-create endpoint, so a book the catalogue has never seen cannot be previewed before it is created; four E2E specs moved from `upload-verify` to `upload-complete` accordingly. This is a real product trade-off and is **raised to the owner** rather than absorbed. (2) No "add as separate" on the merge prompt — `confirm/2` has no force-create option, so the button is deliberately absent rather than offered-and-broken; US-1.1.6's "No, it's different" would need a server affordance. (3) `frontend/index.html` is a **tracked 39,680-line stale Elm build artefact** that still contains the deleted `lookupByIsbn` — not served (the app loads `app.js` via esbuild), so it is dead output under version control → **#348**. (4) No `ConfirmBookRequest` message in `requests.proto` though `BookConfirmResponse` exists — minor contract asymmetry.
**Owner ruling 2026-07-31 on finding (1):** ACCEPTED as built. The "We think this is…" preview is not restored and `GET /api/books/resolve?isbn=` is **not** to be built. A wrong add is covered by the Wave 7 undo affordance instead — recorded against wave item **7c**, which now carries the manual-add case alongside undo-remove. Rationale: consistent with the standing inform-never-block ruling — act, then make it trivially reversible — at zero additional server cost.
