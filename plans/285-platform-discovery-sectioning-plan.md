# Plan: Platform Discovery Search Sectioning (Phase-1 scope)
**Issue**: #285
**Created**: 2026-07-24
**Status**: Approved (owner-confirmed scope, 2026-07-24)

## Context
Owner-confirmed scope: "Your Collection" section (placement-scoped search — delivers US-1.5.1's original collection promise) above "On the Platform" (existing platform book search), where platform results carry labels when discoverable-by-design: looking_for_home placements ("Looking for a home on [handle]'s shelf") and active listings ("Listed by [handle] for R[price]"), per the US-10.2.2:52 marketplace exception and the implemented `listing_status` denormalisation. Partner inventory + events deferred (Phase 3; no user-facing surfaces exist). US-18.1.1 (`looking_for_home`, extended Phase 1) is the advertising anchor.

## Phases

### Phase 1: Contract (proto)
**Agent**: elixir/protobuf specialist
Additive extension of `SearchResponse` (proto/book_responses.proto:55-66): new repeated field for collection results + a hit wrapper carrying label metadata (source kind: none|looking_for_home|listed; owner_handle; price for listed). Field numbers additive-only, never reuse. Regenerate BOTH targets (`just run mix proto.sync` + `scripts/gen-elm-proto.sh`) + run elm-test (the two-target memory rule). buf lint clean.

### Phase 2: Backend
**Agent**: elixir-agent
- New collection-scoped query (join op.bookshelf_placements → op.books on title_tsv match for the current user; active placements only).
- Platform side: existing `search_books/2` + a label join: looking_for_home placements with `listing_status: "active"` always-visible (US-10.2.2:52); active listings via the Marketplace context.
- Controller: sectioned response per the new contract; existing `Visibility.can_view?` filtering retained on platform books; labels ONLY for always-visible LFH/listed placements (never leak private shelf provenance).
- GDPR lens (mandatory): owner_handle exposure rides existing public-handle rules; no new PII path; erasure/export unaffected (no new persisted data). State the verdict.
- Tests: collection scoping (own book found in section 1, not duplicated in section 2; other users' private books absent), label correctness + exclusion (private LFH? impossible by design — assert the always-visible rule), payload shape.

### Phase 3: Elm (BLOCKED until #290 lands — same file)
**Agent**: elm-agent
Sectioned rendering in Page.Search via the regenerated decoders; labels; empty-section handling; compose with #290's Relevance default + copy. Program tests per section + labels.

### Phase 4: E2E
**Agent**: testing-coordinator
Seeded drive: place a book on the suite user's shelf → appears under "Your Collection"; a seeded LFH/listed book (another user) appears under "On the Platform" with its label. Deterministic, no vacuous guards.

## Coordination
- #286: resolved separately as removal (owner-confirmed) — nothing in `search_platform/2` salvageable for this design.
- #284 (deep search) runs AFTER #285 completes (both reshape SearchController + Page.Search).
- #289 (click-through) slots after #290, before Phase 3 of this plan.

## Proving gate
Live drive: authenticated search shows both sections with a real collection hit + a real labelled LFH/listing hit; unauthenticated (if search requires auth — it does, :authenticated pipeline) n/a.
