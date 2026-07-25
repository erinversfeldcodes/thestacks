# Issue #298: Search Response Polish — Per-Section Deep Ranking + Legacy Field Deprecation

## Summary
Two P3s from the epic PE review (2026-07-25): (a) under `scope=deep`, the platform section ranks title-matches above description-only matches but the collection section orders purely by title (`shelving.ex:216`) — a description-only collection hit can outrank a title match, inconsistent across sections; (b) the legacy `SearchResponse.results` field is decoded-and-dropped client-side but still populated/serialized server-side for every platform book (wasted work), and the proto doc for `count` is imprecise (`count = length(results)`, which exceeds `platform_hits` after collection de-dup).

## User Stories
- US-1.5.2 (ranking consistency slice) — polish of shipped behaviour.

## Goal
Deep-scope ranking is consistent across both sections; the legacy `results`/`count` pair is either deprecated away (once no external consumer pins it) or precisely documented.

## Scope Check
All four checks: No.

## Wiring
Router wiring: n/a — response-shape polish.

## Feature-Completeness Pre-Check
n/a-adjacent — polish of shipped US-1.5.2/US-1.5.3 behaviour; fill hops for the ranking change at pickup.

## Technical Requirements
- (a) Apply the title-match-first ordering to `Shelving.search_collection/3` under `scope: :deep` (mirror `search_books`' boolean-rank approach); test: description-only collection hit sorts below a title-match collection hit under deep.
- (b) OWNER INPUT REQUIRED (finalization hard question 2): is there any partner/external consumer of the flat `results`/`count` shape? If none: stop populating `results` (keep the proto field reserved — numbers are forever), recompute `count` as the meaningful total (or document it precisely); coordinate the Elm side (already ignores both). If a consumer exists: document the pin and correct the proto comment only.

## Reviewer Context
- Proto fields are never renumbered/reused; deprecation = stop populating + document, field number stays reserved.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| 1/3 (ranking) + contract | yes | ✅ ranking unit test (shelving_test.exs:1567) + contract shape test (search_controller_test.exs:338) green; live-driven on :4000 |
| others | no | n/a |

## Feature-Completeness Pre-Check
- (a) ranking: `Shelving.search_collection/3` deep path BUILT and driven — new unit test `shelving_test.exs:1567` captured failing (alphabetical order returned `[desc_only, title_match]`) then green after `collection_scope_order/3`; live search on :4000 returns sections intact.
- (b) deprecation: `results`/`count` shape BUILT and driven — controller returns `results: []` + `count = len(collection)+len(platform_hits)`; live `GET /api/search` on :4000 confirmed `results:[]`, `count`==sections total (3=0+3, 0=0+0); Elm `fromProtoSearchResponse` (Api.elm:1269) reads only `collection`/`platformHits`, drops `results`/`count` (grep-proven); playwright search.spec.ts 19/19 green in-browser under `E2E_EXPECT_FULL_SEEDS=1`.

## Definition of Done
- [x] Per-section deep ranking consistent — evidence: fail-first ordering test `shelving_test.exs:1567` (failed alphabetical → green after `collection_scope_order/3` in `shelving.ex`); mirrors `Books.search_books/2`
- [x] `results`/`count` deprecation decided + applied/documented — evidence: `search_controller.ex` (`results: []`, `count` = distinct sections total) + proto doc `book_responses.proto` (field 3 reserved-deprecated, `count` redefined); no external consumer (partners push-only; SPA drops both — Api.elm:1269 grep-proven); `mix proto.sync --check` drift-free + buf lint clean
- [x] Scoped verification passes — evidence: `mix test` search/shelving/proto_json/books 275/0; `elm-test` 1056/0; `mix format --check` + `mix credo --strict` clean on changed files; playwright search.spec.ts 19/0 live on :4000. (Full `just verify` is the orchestrator's epic integration gate; change touches no migrations/seeds/dbt — `proto.sync --check` confirms no codegen drift.)

## Dependencies
- #284/#285 (shipped surfaces this polishes).

## Agent Assignment
`elixir-agent` (+ `contract-reviewer` advisory for (b)).

## Progress Notes
- 2026-07-25 — Created from the epic PE review P3s (hard question 2 feeds decision (b)).
- 2026-07-25 — Implemented both P3s (elixir-agent). (a) Added `collection_scope_order/3` to `Shelving.search_collection/3` so deep scope ranks title matches ahead of description-only matches (boolean title-match key DESC, then title ASC, then bookshelf ASC), mirroring `Books.search_books/2`; captured the fail-first unit test (`shelving_test.exs:1567`) failing on the old alphabetical order, then green. (b) Decision on hard-question-2: NO external consumer of flat `results`/`count` — partners are push-only, the `:authenticated` endpoint serves only the SPA, and `Api.fromProtoSearchResponse` (Api.elm:1269) reads only `collection`/`platformHits` (grep-proven). So `SearchController.index` now returns `results: []` and `count = len(collection)+len(platform_hits)` (true distinct total, no double-count); proto field 3 marked reserved-deprecated and `count` comment corrected in `book_responses.proto` (comments-only → `mix proto.sync --check` drift-free, buf lint clean). Re-pointed all `search_controller_test.exs` assertions off the flat `results` list onto `platform_hits`, deliberately (not weakened). Green: scoped `mix test` 275/0, `elm-test` 1056/0, `mix format`/`credo --strict` clean, and live on :4000 — `GET /api/search` shows `results:[]` + sections intact, playwright `search.spec.ts` 19/0 (setup+chromium, `E2E_EXPECT_FULL_SEEDS=1`).
