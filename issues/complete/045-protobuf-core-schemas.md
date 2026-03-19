# Issue #045: Protobuf Core Schemas

## Summary
Author the core `.proto` files: event bus envelope, book/edition messages, and location messages. Configure `buf lint` and `buf generate` for Elixir + Elm. Establish `buf breaking` baseline on `main`.

## User Stories
Cross-cutting — event bus contract, book data contract used by all enrichment + marketplace stories.

## Goal
Protobuf is no longer aspirational — `.proto` files exist, compile, lint, and generate code for Elixir and Elm. The event envelope defines the contract for `Stacks.Events.emit/1`.

## Technical Requirements

**Proto files to create:**
- `proto/stacks/internal/event_bus.proto` — `EventEnvelope` message: `string event_type`, `string aggregate_type`, `string aggregate_id`, `int32 schema_version`, `google.protobuf.Struct payload`, `google.protobuf.Struct metadata`, `google.protobuf.Timestamp occurred_at`.
- `proto/stacks/common/book.proto` — `Book` (work: id, title, author_id, description, subjects, visibility_tier), `Edition` (id, book_id, isbn, format enum, is_primary, cover_image_url, page_count, publisher, publication_year), `Author` (id, name, website_url, rss_feed_url), `ISBN` (value, format enum ISBN10/ISBN13).
- `proto/stacks/common/location.proto` — `Country` (code, name), `City` (name, country_code), `Coordinates` (latitude, longitude).

**Configuration:**
- `buf.yaml` — lint rules (STANDARD + COMMENTS for required comments on messages)
- `buf.gen.yaml` — Elixir target (protobuf-elixir), Elm target (elm-protobuf or manual JSON decoders)
- Run `buf generate proto/` and verify output
- Elm decoders checked into `proto/gen/elm/` (Elm has no runtime codegen)
- Elixir modules generated to `proto/gen/elixir/` (gitignored or checked in per project convention)

**Integration:**
- Update `Stacks.Events.emit/1` to structure payloads conforming to `EventEnvelope` schema (validation optional at this stage — contract documentation is the priority)
- Document in a comment: "Event payloads should conform to EventEnvelope proto. Validation enforcement planned for Issue #NNN."

**Partner protos deferred:** `inventory.proto`, `events.proto`, `spaces.proto` are Phase 2 deliverables.

## Definition of Done
- [ ] `buf lint proto/` passes with zero errors
- [ ] `buf generate proto/` produces valid Elixir and Elm code
- [ ] Generated Elixir modules compile (`mix compile`)
- [ ] Generated Elm decoders compile (`elm make`)
- [ ] `buf breaking proto/ --against '.git#branch=main'` baseline established
- [ ] `EventEnvelope`, `Book`, `Edition`, `Author`, `Location` messages defined
- [ ] CI step added: `buf lint proto/` runs on every PR touching `proto/`

## Dependencies
None (can run in parallel with Issues #042-044)

## Agent Assignment
protobuf-agent

## Progress Notes

2026-03-19 — Implementation complete. All proto files created, buf lint passes (zero errors), Elm decoders checked in, CI lint-proto job present. Orchestrator review: APPROVED with two non-blocking notes: (1) `Stacks.Events.emit/1` missing explicit EventEnvelope conformance comment — address in Issue #046; (2) `schema_version` not set in `emit/1` params map — address in Issue #046. Forward compatibility: READY for Issues #046, #047, and Phase 2B partner protos. Completion record: `plans/045-protobuf-core-schemas-complete.md`.
