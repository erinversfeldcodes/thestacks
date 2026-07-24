# Issue #296: Remove the Lossy Catalogue Search Sanitiser

## Summary
Sibling of #291: an identical `String.replace(query, ~r/[^\w\s]/, "")` transform lives in `Stacks.Books.maybe_search/2` (`apps/core/lib/stacks/books.ex:637`, the catalogue-listing path used by `list_catalogue`), with the same lossy behaviour — catalogue searches for "O'Brien"/"Spider-Man" silently degrade. Remove it the same way, test-first, with the same injection-safety rationale (Ecto binding; verify which query mechanism this path uses — `ilike` vs tsquery — and assert accordingly).

## User Stories
- Catalogue browsing/search story (see docs/user-stories.md catalogue section; discovery surface)

## Goal
Catalogue search matches apostrophe/hyphen titles; no lossy char-stripping remains in `books.ex`.

## Scope Check
All four checks: No (one line + tests).

## Wiring
Router wiring: n/a — behaviour fix in an existing path.

## Feature-Completeness Pre-Check
n/a — single-mechanism correctness fix inside a shipped surface; validation = fail-first tests + suites green.

## Technical Requirements
- Read `maybe_search/2` first: it may feed `ilike` (catalogue) rather than `plainto_tsquery` — if `ilike`, confirm the bound-param escape story for `%`/`_` wildcards before removing the strip (a raw `%` in an ilike pattern changes semantics — if so, escape wildcards specifically instead of stripping ALL punctuation, and test both an apostrophe match AND that a literal `%` doesn't act as a wildcard).
- Fail-first tests in `books_test.exs` (catalogue describes) mirroring #291's pattern.
- Sweep: after this, `grep -n "~r/\[^" apps/core/lib/stacks/books.ex` shows no remaining char-strip sanitisers.

## Reviewer Context
- #291 (commit 0d15326e) removed the search_books/2 twin; its edge-case suite pattern applies.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| 1/3 | yes | ❌ fail-first apostrophe/hyphen (+ wildcard-literal if ilike) tests → ✅ when done |
| others | no | n/a |

## Definition of Done
- [x] Catalogue search matches apostrophe/hyphen titles; wildcard semantics safe — evidence: two fail-first tests in `books_test.exs` "list_catalogue/1 — search" (apostrophe `:336`, hyphen `:348`) FAILED (`right: []`) against current code, GREEN after removing the sanitiser. Wildcard semantics are N/A on this path: `maybe_search/2` uses `plainto_tsquery` (verified — NOT `ilike`), so there are no `%`/`_` wildcards and no escape story needed; the raw query is safe via Ecto bound param.
- [~] No char-strip sanitiser remains in books.ex — the two REACHABLE sanitisers are removed: `search_books/2` (#291, commit 0d15326e) and `maybe_search/2` (this issue). One remains at `books.ex:809` inside `search_platform/2`, which is DEAD CODE (zero callers in `apps/core/lib` / `core_web`; no route) tracked as **#286** and uses `ilike(b.title, ^"%#{safe}%")` — removing its strip blindly would turn a literal `%`/`_` into a wildcard, so it needs the wildcard-escape treatment (the issue's own caution), not a blind removal. Left for #286. Grep now shows only that one occurrence + two new explanatory comments.
- [x] Suites green (`just run mix test` scoped); format/credo clean — evidence: `books_test.exs` + `age_gating_flag_off_test.exs` = `70 tests, 0 failures`; `mix format --check-formatted` exit 0; `mix credo --strict apps/core/lib/stacks/books.ex` no issues.

## Dependencies
- #291 (pattern + rationale).

## Agent Assignment
`elixir-agent`.

## Progress Notes
- 2026-07-24 — Created from #291's out-of-scope flag (second identical sanitiser at books.ex:637).
- 2026-07-24 — Removed the `String.replace(search, ~r/[^\w\s]/, "")` transform in `maybe_search/2` (books.ex:637, shared by `list_catalogue/1` + `list_for_moderation/1`); raw query now passes to the existing bound `plainto_tsquery` param. CAUTION RESOLVED: verified this path uses `plainto_tsquery`, NOT `ilike` — so no wildcard-escape needed; a literal-% test is N/A here. TEST-FIRST: added apostrophe + hyphen catalogue-match tests to `books_test.exs` ("list_catalogue/1 — search"); both FAILED fail-first (`right: []`), both GREEN after. Suites 70/0; format+credo clean. SWEEP found a THIRD sanitiser at books.ex:809 in `search_platform/2` — this IS an `ilike("%#{safe}%")` path, but it is DEAD CODE (no callers) already tracked as #286; blind strip removal there would break wildcard semantics, so deferred to #286 with the escape-not-strip note.
