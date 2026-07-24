# Issue #291: Remove the Lossy Search Query Sanitiser

## Summary
`Stacks.Books.search_books/2` strips non-word characters before tokenisation (`safe_query = String.replace(query, ~r/[^\w\s]/, "")`, books.ex:698). #115's review proved it is (a) security-redundant — removing it fails zero tests; injection safety comes from Ecto param binding + `plainto_tsquery` (empirically: `to_tsquery` swap fails 5 tests, sanitiser removal fails none) — and (b) **lossy**: "O'Brien" → "OBrien" and "spider-man" → "spiderman", changing lexemes and degrading legitimate searches for titles/authors with apostrophes or hyphens.

## User Stories
- US-1.5.1 — Search Across Shelves (correctness slice)

## Goal
Searching "O'Brien" or a hyphenated title matches the intended books; the redundant transform is gone; a regression test pins the apostrophe/hyphen behaviour.

## Scope Check
All four checks: No (one line removed + tests).

## Wiring
Router wiring: n/a — behaviour fix inside the existing search path.

## Feature-Completeness Pre-Check
n/a — single-mechanism correctness fix inside a shipped story; validation is the new tests + live drive of an apostrophe search.

## Technical Requirements
- Remove the `safe_query` transform in `search_books/2`; pass the raw query to `plainto_tsquery` via the existing bound param.
- Add tests first (they should FAIL against current code): seed "The Master of O'Brien Manor" (or an author O'Brien surfaced via title), search `O'Brien`, assert match; hyphen case similarly. Keep the #115 injection/operator/long-query tests green (they must pass unchanged — they don't depend on the regex).
- Verify no other caller depends on the sanitised form.

## Reviewer Context
- The #115 edge-case suite (search_controller_test.exs "query edge cases") is the safety net proving injection-safety is unaffected by this removal.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| 1 (API) + 3 (DB) | yes | ❌ apostrophe/hyphen match tests needed (fail-first) → ✅ when done |
| others | no | n/a — one-line mechanism fix; no new surface |

## Definition of Done
- [ ] Apostrophe + hyphen searches match seeded books — evidence: fail-first tests now green
- [ ] #115 edge-case suite untouched and green — evidence: suite run
- [ ] `just verify` passes; **`completion-audit` passed**; **Completion Bar met** (live-drive an O'Brien search)

## Dependencies
- #115 (edge-case safety net, merged on feat/115-114-3-e2e)

## Agent Assignment
`elixir-agent`.

## Progress Notes
- 2026-07-24 — Created from #115 elixir-review P3 (lossy + redundant, empirically demonstrated).
