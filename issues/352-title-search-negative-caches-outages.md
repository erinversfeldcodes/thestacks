# Issue #352: Title search turns an outage into a cached "no such book" for an hour

## Summary
Found by #344 and left deliberately unfixed because it changes a contract. `ISBNResolver.search_by_title/4` is the last defect site of the class #344 closed everywhere else:

1. `try_candidate/4` maps **every** Open Library *and* Google Books error to `nil` — a transport failure, a 503 and a genuine miss are indistinguishable;
2. the function therefore returns `{:error, :not_found}`, asserting a fact about the ISBN when it only knows a fact about us;
3. **`TitleSearchCache` then negative-caches that answer for an hour.**

So a brief provider outage does not merely mislead one reader — it is *persisted* as "this book does not exist" and served to every subsequent reader for the next 60 minutes, long after the providers recover.

## Why #344 stopped here
#344 split `ISBNResolver`'s errors into `:not_found` (both catalogues answered — a fact about the ISBN) versus `:unavailable` (a fact about us), and fixed six collapse sites. It deliberately did **not** touch this one, because doing so changes `search_by_title/4`'s public contract, the twelve-variant "last error" semantics behind it, and the cache-write policy. That is a separate, larger change and belongs in its own issue rather than smuggled into a fix for something else. Correct call — recorded here so the remaining gap is not mistaken for completeness.

## User Stories
US-1.1.2 (ISBN gate provenance), US-1.1.3 (photo → book).

## Goal
The title-search path distinguishes "we asked and the answer is no" from "we could not ask", and never caches the latter.

## Scope Check
One resolver function's contract + its callers + the cache-write policy. Larger than it looks because of the twelve error variants — **scope it before building**; if it exceeds the bar, split the cache policy from the contract.

## Wiring
Router wiring: none. Internal resolver contract.

## Feature-Completeness Pre-Check
n/a — no new story surface. The pre-check that matters is the cache sweep: confirm negative entries currently persist provider failures.

## Technical Requirements
1. **Extend the `:not_found` / `:unavailable` split to `search_by_title/4`.** #344 built `ISBNResolver.determination/1` with no catch-all, mirroring `VisionError.determination/1`. Reuse it — do not invent a third convention.
2. **Never negative-cache an unavailability.** A cache entry should record an answer, never the absence of one. Decide what happens to entries already written — they expire in an hour, so a backfill is probably unnecessary, but say so rather than leaving it implied.
3. **Update `title_fallback/5` in `moderation.ex` accordingly.** #344 deliberately left it without a catch-all, on the grounds that the only guess available (`:isbn_not_found`) is the exact untruth being removed. Once `search_by_title/4` can return an unavailability, that clause becomes reachable and must be handled honestly — and #344's closed-set test (six reachable failure modes) is what will tell you.
4. **Check the other callers** of `search_by_title/4` before changing its return shape.

## Reviewer Context
- BOOTSTRAP: **`just bootstrap-worktree`** from inside the worktree, then `git merge --ff-only <wave branch>` (local, unpushed — no `git fetch`).
- **NEVER bare `mix`** — `just run mix …`. **`caffeinate -i`** for long suites. **NEVER `git checkout`** to revert a probe — Edit, then `grep -c`. Stage incrementally.
- ⚠️ **Expect a test to be defending the current behaviour.** #344 found `upload_pipeline_test.exs` carried a story-tagged test named *"merge_format endpoint surfaces 503 ISBN-service outage as 422 isbn_not_found"*, whose comment argued the defect was "graceful degradation". Read what a failing test is actually asserting before assuming your change is wrong.
- ⚠️ The twelve-variant "last error" semantics are the reason this is bigger than it looks — read them before editing.
- `:fuse` is global ETS and survives the sandbox; tests that melt it need the module-level `:fuse.reset/1` guard used in `isbn_resolver_test.exs`, `book_controller_test.exs` and (since #344) `moderation_test.exs`.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| External services | yes | ❌ an outage during title search is not reported as `:not_found` — probe by restoring the collapse |
| External services | yes | ❌ an outage is **not** written to `TitleSearchCache` — assert the cache is untouched, not just the return value |
| Oban jobs | yes | ❌ `title_fallback/5` handles the newly-reachable variant honestly |
| Others | no | n/a |

## Definition of Done
- [ ] `:not_found` / `:unavailable` split reaches `search_by_title/4` via `determination/1` — evidence: diff
- [ ] No negative cache entry on unavailability — evidence: test asserting cache state
- [ ] `title_fallback/5` handles the now-reachable variant — evidence: test name
- [ ] Other callers checked — evidence: the list
- [ ] Mutation probes with red output quoted — evidence: transcripts
- [ ] Suites green — evidence: counts
- [ ] `staff-review` verdict recorded below

## Dependencies
**#344** (built `determination/1` and fixed the sibling sites; this is the one it consciously left). Needs an owner wave assignment.

## Agent Assignment
elixir-agent.

## Progress Notes
Filed 2026-07-31 by the lead from #344's finding 2.
