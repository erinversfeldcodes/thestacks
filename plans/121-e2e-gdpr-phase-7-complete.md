# Phase 7 Complete — Issue #121: Resolve PE-gate P0 (event_log PII erasure)

**Status**: APPROVED (elixir-reviewer, security lens, 0 revision cycles)
**Agent**: elixir-agent · **Reviewer**: elixir-reviewer (security)
**Type**: production code — GDPR right-to-erasure fix (security-critical)

## Why this phase exists
The 2F Principal Engineer gate returned YELLOW with a **P0**: user PII
(`display_name`, `city`, `country_code`) survived in `op.event_log` payloads
after account deletion, and Phase 1 had rewritten two moduledocs + a test to
falsely assert "no PII / nothing to scrub" — cementing the leak. Contradicted
CLAUDE.md's invariant. Human decision: remediation = **Both**, home = new
#121 Phase 7.

## What landed (remediation "Both", refined to fully-clean)
1. **Emitters UUID-only** — all `user.*` event payloads dropped to `%{}`
   (`accounts.ex`: `user.profile_updated` ×2, `user.location_updated`). Full
   emit-site sweep (~55 sites) confirmed no other PII payloads.
2. **Handler refactor** — `location_updated_handler.ex` no longer reads
   city/country from the (now-empty) payload; it resolves the user by
   `aggregate_id` and reads current city/country off the record, enqueuing
   `GeographicDiscoveryJob`. Graceful `:ok` on absent/incomplete user.
   Documented semantic shift (current vs as-of-event location).
3. **Scrub-on-erasure** — new atomic `:scrub_event_log` Multi step in
   `deletion.ex`: `UPDATE op.event_log SET payload='{}', metadata='{}' WHERE
   aggregate_type='user' AND aggregate_id=<user>`. Rows preserved (immutability),
   PII redacted. event_log has no append-only trigger → plain UPDATE, no GUC.
4. **Corrected moduledocs** (`events.ex`, `deletion.ex`) to the true contract.
5. **Rewrote the deletion event_log test** — seeds a real PII-bearing user event
   + an unrelated `book` event; asserts user rows survive with payload/metadata
   emptied, unrelated row byte-identical (guards over-scrubbing). Real teeth.
6. **P2 (folded in)** — documented (code + PromEx description) that
   `image.expired` must be queried split by `:reason` and never summed with
   `:stuck`; kept the series 1:1 with domain events (lower-risk than dropping it).

## Gates
- 2A-i Failing-test: 4 genuine assertion failures pre-impl (handler no-enqueue,
  missing `:scrub_event_log`, payloads still PII). ✅
- 2B-i Regression: **2230 tests, 0 failures, 10 excluded** (orchestrator re-run).
- 2C Review: elixir-reviewer (security lens) → **APPROVED** first pass. Confirmed
  erasure completeness, atomicity, jsonb `{}` correctness, handler atom-key match
  in `subscriber_worker.ex`, non-vacuous tests, accurate moduledocs.

## Reviewer non-blocking notes → epic backlog (NOT this P0)
1. **Cross-aggregate UUID residue** — events *about* the user under a different
   aggregate (e.g. `social.user_blocked` `blocked_id`, `blog.*` `user_id`,
   marketplace `seller_id`) keep bare UUIDs. Consistent with the project's
   "UUIDs are not PII" contract; orphaned after erasure. → note on #185.
2. **`blog.*` free-text `title`** in payloads under `aggregate_type:"post"` is
   non-UUID content the user-scoped scrub won't touch. The primary blog rows are
   cascade-deleted on user delete; the event_log mirror is the residue. → #185
   (deeper deletion cascade).
3. Already-erased-user edge (legacy PII, no user row) — extremely narrow; accepted.

## Separate commit (scope-lock): pre-existing flake fix
`isbn_resolver_test.exs` flipped `async: true → false`. Root cause: its
`capture_resolver_log/1` toggles the **global** Logger level (`:warning`→`:info`)
and restores it in `after`; run async, concurrent calls race and one test's
restore suppresses another's `Logger.info` → the "floored" assertion flaked on
`log == ""` (surfaced in the Phase 7 full-suite run). Unrelated to the P0 —
committed separately. Regression green after the fix (2230/0).
