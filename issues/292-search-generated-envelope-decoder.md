# Issue #292: Adopt the Generated SearchResponse Envelope Decoder in Api.searchBooks

## Summary
`Api.searchBooks` hand-rolls its response decoder (`Decode.field "results" (Decode.list bookDecoder)`) even though a proto message `SearchResponse { query, count, results }` exists (proto book_responses.proto:55-66) and the generated `ProtoBookResp.decodeSearchResponse` is already importable (Api.elm imports the module at :141). Siblings (catalogue :1181, merge-format :1767) decode their whole envelope through generated decoders. The hand-rolled envelope is exactly what allowed #115's bare-array live bug and forces the hand-maintained `TestHelpers.searchEffects` mirror + `searchResponseJson` fixture to stay in sync manually.

## User Stories
None — contract-hygiene refactor (behaviour identical). Validation: existing #115 suites must stay green byte-for-byte.

## Goal
The search envelope is drift-proof by construction: `searchBooks` uses `Decode.map fromProtoSearchResponse ProtoBookResp.decodeSearchResponse` (catalogue pattern), and the hand mirror either uses the same generated decoder or is retired.

## Scope Check
All four checks: No (one decoder swap + a `fromProtoSearchResponse` adapter + test-mirror simplification).

## Wiring
Router wiring: n/a — client-internal refactor.

## Feature-Completeness Pre-Check
n/a — no user stories (contract hygiene); proof = all #115 unit/program/E2E suites green unchanged.

## Technical Requirements
- Swap the decoder in `Api.searchBooks`; add `fromProtoSearchResponse` mapping to the existing client Book type (mirror `fromProtoCatalogueResponse`).
- Point `TestHelpers.searchEffects` at the same generated decoder (or restructure so no separate mirror decoder exists).
- `count`/`query` become available typed — expose to `Page.Search` only if trivially useful (e.g. result count display); otherwise ignore.
- Regenerate Elm protos via `scripts/gen-elm-proto.sh` as part of the build (decoders are gitignored).
- All #115 suites (SearchProgramTest, SearchTest, search.spec.ts 12) must pass unchanged — they are the acceptance gate.

## Reviewer Context
- Per CLAUDE.md, proto is THE schema contract and Elm decoders are generated at build time — search is currently the outlier endpoint.
- Generated decoders are default-tolerant (`D.oneOf [field, succeed default]` per gen-elm-proto.py:358-380) — no strictness regression risk.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| 10 (Elm) | yes | ✅ existing #115 suites are the regression net; add one decodeSearchResponse-shape test if the adapter has logic |
| others | no | n/a — pure client refactor |

## Definition of Done
- [x] searchBooks decodes via generated `decodeSearchResponse`; no hand-rolled envelope remains — evidence: `Api.elm:795` `expect = Http.expectJson toMsg searchResponseDecoder`; `searchResponseDecoder = Decode.map fromProtoSearchResponse ProtoBookResp.decodeSearchResponse` (`Api.elm:1199-1201`); grep `Decode.field "results"` over `frontend/src` + `frontend/tests` → 0 matches
- [x] Hand mirror retired or unified — evidence: `TestHelpers.elm:959` now `expect = ... Api.searchResponseDecoder` (the exact same exposed decoder); no separate `Decode.field "results" (Decode.list bookDecoder)` mirror remains
- [x] All #115 suites green unchanged — evidence: `npx elm-test` → 1008 passed / 0 failed (baseline unchanged); `npx elm-review` → no errors; `npx elm-format --validate` → clean; `search.spec.ts --project=chromium` (local :4000) → 12 passed (10 chromium + 2 setup), incl. the `searchResponseJson`-driven seeded/empty/error/sort/filter specs, assertions unchanged
- [ ] `just verify` passes; **`completion-audit` passed**; **Completion Bar met** — Elm gates (elm-test/elm-format/elm-review) + live search E2E green; full `just verify` + completion-audit deferred to epic-level close (team-lead mandate)

## Dependencies
- #115 (its suites are the acceptance gate, merged on feat/115-114-3-e2e)

## Agent Assignment
`elm-agent` (+ `contract-reviewer`).

## Progress Notes
- 2026-07-24 — Created from #115 contract-review P3 (un-governed envelope; generated decoder already exists unused).
- 2026-07-24 — Implemented. `Api.searchBooks` now decodes through `searchResponseDecoder = Decode.map fromProtoSearchResponse ProtoBookResp.decodeSearchResponse` (generated `SearchResponse` envelope; `fromProtoSearchResponse` maps `proto.results` via `Types.Book.fromProtoBook`, mirroring `fromProtoCatalogueResponse`). Decoder exposed from `Api`; `TestHelpers.searchEffects` now reuses `Api.searchResponseDecoder`, retiring the hand `Decode.field "results" (Decode.list bookDecoder)` mirror. Gates: elm-test 1008/1008, elm-review clean, elm-format clean, search.spec.ts 12/12 (local :4000). Grep sweep for `Decode.field "results"` → 0. Behaviour identical; `query`/`count` dropped at the adapter (page consumes `List Book` unchanged).
