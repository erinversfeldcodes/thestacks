# Issue #344: W5 child — Resolver failures stop masquerading as bad books, and placeholder titles look like placeholders

## Summary
Child of epic #315, Level 3. Two related honesty problems.

**Resolver outages are recorded as the book's fault.** Several sites collapse every resolver error into a single `_` branch, so a Google Books 503 — our dependency being down — is recorded as `:invalid_book`, i.e. "this isn't a real book". That corrupts the rejection-reason funnel that operators read, and it tells the reader something false about their upload.

**Placeholder titles read as real ones.** When enrichment cannot find a title, the system stores a `"ISBN 978…"` placeholder. It renders exactly like a normal entry, so a reader sees a book on their shelf whose title is a number and cannot tell whether that is a bug, a rare book, or a pending lookup.

## User Stories
US-1.1.2 (ISBN gate provenance / D1), US-1.1.1 (failure honesty).

## Goal
A failure is attributed to whatever actually failed. A book we could not identify says so, in the reader's language, rather than wearing an ISBN as a name.

## Scope Check
Error-handling in 3–4 call sites + one Elm treatment. No new endpoints. Under the bar. ⚠️ The `Stacks.Books.ISBN` / `Stacks.Uploads` extraction that the epic bundled here is **#345**, deliberately split off — do not do it in this issue.

## Wiring
Router wiring: none new. The provisional-title treatment is user-facing on completion.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops | Current behaviour | Verdict | Resolution |
|-----------|------------------|-------------------|---------|------------|
| A resolver outage is reported honestly | `_` collapse → `:invalid_book` | a GB 503 is recorded as "not a real book" | ❌ | fix in-scope |
| An unidentified book reads as unidentified | placeholder renders as a title | shelf shows a book called "ISBN 9780…" | ❌ | build in-scope |

## Technical Requirements
1. **Fix the resolver-error collapse sites.** Start by finding them — the epic cites `books.ex:1089`, `book_controller.ex:33/94` and `moderation.ex:467-471`, but **#341 and #343 have both rewritten `books.ex` since those line numbers were taken, so locate them by behaviour, not by line.** The rule: a failure of *our dependency* must never be recorded as a property of the *book*. Match #342's closed `VisionError` set where the error originates there, and mirror `ISBNResolver`'s documented error pattern where it originates there — do not invent a third convention.
2. **`title_fallback/5` catch-all** (`moderation.ex:451-464`). Its `case` handles only `{:ok, isbn, metadata}` and `{:error, :not_found}`. ⚠️ **Determine whether the gap is reachable before writing the test.** `ISBNResolver.search_by_title/4`'s `@spec` is exactly those two returns, so this may be defence-in-depth rather than a live crash — a spec is documentation, not enforcement. **Say which it is**, and if it is defensive, let the test say so rather than dressing it up as a live bug fix.
3. **Provisional-title treatment (D1).** A book whose title is an `"ISBN …"` placeholder must never read as a normal entry. ⚠️ **Use `verification_source` (#335), not a `title LIKE 'ISBN %'` heuristic.** That column exists precisely so "never externally verified" is auditable rather than inferred, and the heuristic silently stops working the moment enrichment succeeds and the title changes. Decide and state what the reader sees — the shape matters more than the wording: it should be legible as *"we haven't identified this yet"*, not as an error the reader caused.
4. **Do not block on it.** A provisional book is a legitimate state (the ISBN gate passed; only enrichment is missing). Per the standing owner ruling, inform — never block.

## Reviewer Context
- BOOTSTRAP: **`just bootstrap-worktree`** from inside your worktree — it copies `.env`, seeds the generated `gen/` tree, copies the esbuild `index.html`, runs `deps.get`, generates all five codegen targets and verifies no drift. Then `git merge --ff-only feat/campaign-w5-315` (**LOCAL, UNPUSHED** — no `git fetch`, no `origin/`).
- **NEVER bare `mix`** — `just run mix …`. **`caffeinate -i`** for long suites. **NEVER `git checkout`** to revert a probe — use Edit, verify with `grep -c`. **Stage incrementally** — an agent stalled this wave and only kept its work because edits were on disk.
- ⚠️ **You are editing `Page/Upload.elm` after #343 rewrote its manual path.** #344 was deliberately sequenced *after* #343 to avoid two agents in that file. Read the new confirm flow before adding to it.
- ⚠️ Proto enums are closed types with a build-failing coverage gate; adding an error code fails the build until every consumer handles it. `bash scripts/lint-proto.sh` checks FIVE targets.
- ⚠️ Run `bash scripts/check-orphan-classes.sh` — a class in markup with no CSS rule is its own defect class. Add **zero**.
- ⚠️ Elm pages with tests must expose `Msg(..)`; `elm-review --fix` narrows it back if no test consumes it.
- Commit: agent commits are DENIED. Stage; ONE-LINE message (no body/trailers) to `/private/tmp/claude-501/-Users-erinversfeld-thestacks/78bc6659-34d4-45c2-b5b7-9a0337db2154/scratchpad/commit-msg-344.txt`. NEVER push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| External services | yes | ❌ a resolver 503 does **not** record `:invalid_book` — assert the recorded reason, and probe by restoring the collapse |
| External services | yes | ❌ `title_fallback/5` handles an unexpected return (or the test states it is defensive) |
| Elm | yes | ❌ a provisional book renders distinguishably, driven by `verification_source` not a title heuristic |
| Elm | yes | ❌ the provisional state does not block any action |
| Others | no | n/a |

## Definition of Done
- [ ] Collapse sites found by behaviour and fixed; each stated — evidence: diff + the list you actually found
- [ ] A resolver outage records a truthful reason — evidence: test name + probe transcript
- [ ] `title_fallback/5` gap classified (live vs defensive) and handled — evidence: the determination + test
- [ ] Provisional treatment driven by `verification_source` — evidence: diff showing no title heuristic
- [ ] Provisional state blocks nothing — evidence: test asserting the flow still advances
- [ ] `check-orphan-classes.sh` zero new orphans — evidence: output
- [ ] Suites green under `caffeinate` — evidence: counts
- [ ] `staff-review` verdict recorded below

## Dependencies
Epic #315. **Depends on #341, #342, #343** — it matches #342's closed error type, and edits `Page/Upload.elm` after #343 settled it. Level 3. **Precedes #345** (which moves this code).

## Agent Assignment
elixir-agent + elm-agent.

## Progress Notes
Filed 2026-07-31 (Wave 5, Level 3). Split from the epic's item 4, whose extraction half is #345.
Lead pre-check: `title_fallback/5` confirmed at `moderation.ex:451-464` with exactly two `case` clauses, and `ISBNResolver.search_by_title/4`'s `@spec` (`isbn_resolver.ex:213-214`) is exactly those two returns — hence the "classify before claiming" requirement above.
