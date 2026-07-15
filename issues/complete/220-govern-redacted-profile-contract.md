# Issue #220: Govern the redacted public-profile shape via proto codegen

## Summary
`ProtoJSON.public_profile/2` and `public_profile_summary/1` are hand-rolled Elixir
maps, and their Elm counterparts (`publicProfileDecoder`, `publicProfileSummaryDecoder`)
are hand-written — the redacted profile shapes bypass the proto/codegen contract
path entirely. There is no `buf`/codegen guard against Elixir↔Elm drift on this
surface. The #210 `display_name: null` decode bug (server emitted null, strict Elm
decoder crashed → real profile falsely 404'd) was a direct symptom of this
unguarded seam.

## Goal
The redacted profile contract is schema-governed, so a server/client drift fails
CI instead of production.

## Scope (pick one)
- Define `PublicProfile` + `PublicProfileSummary` proto messages (redacted subsets)
  and generate the Elm decoders, so the shapes are single-sourced; OR
- If kept hand-rolled: add a decoder round-trip test that locks the exact key set
  (handle, display_name, website_url, city, country_code, bookshelves[].name) and a
  serializer test asserting the SAME keys — a two-sided contract test that fails on
  drift. (#210 already added a partial decoder test; extend it to the serializer.)

## Definition of Done
- [ ] Elixir↔Elm drift on the redacted profile shape is CI-detectable.

## Delegation spec (agent)
Take the **lighter option** (two-sided contract test) — do NOT introduce new proto messages
(that's a bigger change; note it as a future option only).
**Files:** `apps/core/test/stacks_web/proto_json_test.exs` (serializer side), `frontend/tests/Page/ProfileTest.elm` (decoder side — a partial decoder test already exists there).
**Acceptance criteria:**
1. An Elixir test asserts `ProtoJSON.public_profile/2` emits EXACTLY the key set `handle, display_name, website_url, city, country_code, bookshelves` (each bookshelf: only `name`) — fails if a key is added or removed (use `Map.keys |> Enum.sort` equality, not just `has_key?`). Same for `public_profile_summary/1`: EXACTLY `handle, display_name, city, country_code`. Include a case with `display_name: nil` asserting it serialises to `""` (guards the #210 coalesce).
2. The Elm decoder round-trip test locks the same key set: a full-payload decode succeeds; a payload with `display_name: null` and absent optionals decodes to `""` (already present — keep); assert the decoded record type carries no PII field (structural).
3. A one-line comment in each test cross-references the other side so a future dev knows they're a paired contract.
**Verify:** `just run just verify` green (elixir + elm-test). The tests must FAIL if someone adds `email:` to `public_profile/2` — sanity-check by temporarily adding it locally (then revert).

## Source
contract-reviewer P3 + principal-engineer process note, #210 epic review.
