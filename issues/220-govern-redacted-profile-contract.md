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

## Source
contract-reviewer P3 + principal-engineer process note, #210 epic review.
