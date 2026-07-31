# Phase 1 Complete: Audit + telemetry helper

**Issue**: #137
**Phase**: 1 of 7
**Agent**: elixir-agent
**Reviewer**: elixir-reviewer
**Verdict**: APPROVED
**Completed**: 2026-04-29

## Deliverables

- `apps/core/lib/stacks/audit.ex:79-107` — `Stacks.Audit.log_rollback/1` (29 LOC) + `@spec` + `@doc`
- `apps/core/test/stacks/audit_test.exs:53-192` — `describe "log_rollback/1"` block with 10 tests covering happy path, all four `triggered_by` values, `modal_prev_commit: nil` round-trip, telemetry-on-success, telemetry-not-emitted-on-failure

## Behaviour locked

- Wraps existing `Stacks.Audit.log/3` with `action: "system.rollback"`, `resource_type: "deploy"`, `user_id: nil`.
- Metadata carries atom keys: `:failed_sha`, `:target_image`, `:modal_prev_commit`, `:reason`, `:triggered_by`.
- `failed_sha` (git SHA) carried in `metadata`, not `resource_id` — the audit table column is `:binary_id` (UUID), and `encode_uuid` returns `nil` for non-UUID strings. Documented in `@doc`.
- `:telemetry.execute([:stacks, :system, :rollback], %{count: 1}, metadata)` fires **only** on `{:ok, _}` insert. A failed audit insert does not emit telemetry — so a "we rolled back" signal never fires for an unrecorded rollback.
- `modal_prev_commit: nil` preserves the key with a `nil` value (vision-skip case).

## Gate Results

- 2A-iv Reception Gate: PASS (DoD evidence + testing-coordinator both clean)
- 2B-i Regression Gate: PASS — `mix test` 1958 tests, 0 failures
- 2B-ii Spec Coverage Gate: PASS — all section-5 Technical Requirements satisfied
- 2B-iia Fresh DB Gate: SKIPPED — no migrations or schema changes
- 2B-iii Deploy Preview + E2E: SKIPPED — helper has no callers yet; verified via unit test only

## Reviewer Notes (non-blocking, carried forward)

1. Atom→string key round-trip: helper returns the raw input map, so tests can assert atom-key access. If a future consumer reads an audit row back from `audit.audit_log`, JSONB will decode to **string** keys via Cloak's decryption + `Jason.decode!`. Flag for any future operator dashboard / retro query that consumes encrypted metadata.
2. Failure-injection technique (tuple-in-`:reason` to break `Jason.encode!`) relies on the `rescue` clause at `audit.ex:54-56`. If `log/3` ever validates input shape before encoding, this test will start passing for the wrong reason.
3. `triggered_by` allow-list is documented but not runtime-enforced — acceptable while the helper has a single call site (composite action, Phase 3).

## Forward Compatibility

Phase 3's `mix run -e 'Stacks.Audit.log_rollback(%{...})'` call site is **READY** — signature is stable, atom keys + nil-able `modal_prev_commit` work in Elixir source literals.
