# Issue #098: Document review_fetcher as Intentional Stub

## Summary
`review_fetcher` defaults to `MockReviewFetcher` in all environments including prod. Unlike all other client configs which default to real implementations, there is no real `ReviewFetcher` — only the behaviour and mock exist.

## Goal
Document this as intentional (stub until a review source API is integrated) so it's not mistaken for a bug.

## Scope Check
- Add a comment in config.exs
- ~3 lines

## Definition of Done
- [ ] Config.exs has a comment explaining the mock default
- [ ] Consider: should this become an issue to implement a real ReviewFetcher?

## Priority
P2 — fix during Wave E

## Agent Assignment
Any
