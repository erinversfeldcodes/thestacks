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
| 1/3 (ranking) + contract | yes | ❌ ranking test + contract doc/behaviour → ✅ when done |
| others | no | n/a |

## Definition of Done
- [ ] Per-section deep ranking consistent — evidence: fail-first ordering test green
- [ ] `results`/`count` deprecation decided + applied/documented — evidence: diff + proto doc
- [ ] `just verify` passes

## Dependencies
- #284/#285 (shipped surfaces this polishes).

## Agent Assignment
`elixir-agent` (+ `contract-reviewer` advisory for (b)).

## Progress Notes
- 2026-07-25 — Created from the epic PE review P3s (hard question 2 feeds decision (b)).
