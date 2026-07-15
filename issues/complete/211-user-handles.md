# Issue #211: User Handles — schema, backfill, validation, auto-generation

## Summary
Give every user a unique, human-readable **handle** that keys their public profile at
`/u/:handle` instead of a UUID: a proto field + migration, a case-insensitively-unique
index, a deterministic backfill for existing rows, registration auto-generation, a reserved-word
list, and the `Accounts` validation/lookup functions. Backend only — no UI (the settings
edit is #212, the profile surface is #213).

## User Stories
- **US-10.5.1** — Claim a Public Handle (`docs/user_stories/US-10.5.1-public-handle.md`) — the schema/validation/auto-gen half.

## Goal
`op.users.handle` is `NOT NULL`, case-insensitively unique, backfilled for every existing
row, and auto-generated at registration; `Accounts.validate_handle/1` rejects bad format /
reserved / taken with a specific error, and `Accounts.get_user_by_handle/1` resolves
case-insensitively.

## Scope Check
- >3 controllers? No (0 — context + migration only).
- >2 new endpoints? No (0).
- >~300 LOC? No.
- Combines unrelated concerns? No — all handle-schema.

## Wiring
- [ ] User-facing router wiring. — no.
- [x] Implementation only. The handle is surfaced/edited by **#212** (settings) and consumed by **#213** (profile read).

## Feature-Completeness Pre-Check

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-10.5.1 — Claim a Public Handle (schema/validate/auto-gen half) | `Accounts.register/1` auto-gens (`apps/core/lib/stacks/accounts.ex:294` → `generate_handle/1` :213) → `validate_handle/1` (:169) enforces format/reserved/unique → `get_user_by_handle/1` (:259) case-insensitive lookup; migrations `20260714200119_add_handle_to_users.exs` + `20260714200500_backfill_and_constrain_user_handles.exs` (NOT NULL + `lower(handle)` unique index) | ✅ verified by suite — `accounts_test.exs:78` register auto-gen produces a slugified valid handle; backfill migration constrains existing rows | ✅ | built end-to-end (backend); the *editable field* half is #212 |

Verdict: ✅ implemented (backend). The user-visible edit path is US-10.5.1's #212 half — tracked there, not a gap here.

## Technical Requirements
- Proto: `string handle = 32` on the `User` message → `mix proto.sync` regenerates the Ecto schema (`apps/core/lib/stacks/gen/`, do not hand-edit) + `stg_users.handle`.
- Migration 1 (`20260714200119`): add `handle` column.
- Migration 2 (`20260714200500`): deterministic backfill (`slug(display_name)` → numeric-suffix dedupe → `user-<id8>` fallback), then `NOT NULL` + `CREATE UNIQUE INDEX users_lower_handle_index ON op.users (lower(handle))`.
- `Accounts.generate_handle/1`: `slug(display_name) + "_" + <6-char random>`; `reader_<random>` for blank/emoji-only names.
- `Accounts.validate_handle/1`: force-lowercase, `validate_format(~r/^[a-z0-9_]{3,30}$/)`, `validate_exclusion` against `Stacks.Accounts.ReservedHandles`, `unique_constraint(:handle, name: :users_lower_handle_index)`.
- `Stacks.Accounts.ReservedHandles.reserved?/1` — includes `u` + every top-level SPA segment + impersonation-sensitive words (`admin`/`api`/`support`).
- `Accounts.get_user_by_handle/1` — `lower(handle) = lower($1)`, trims input.

## Reviewer Context
- Backfill correctness is the top risk: nullable, non-unique `display_name` guarantees slug collisions/empties — the dedupe + `user-<id8>` fallback + CI-enforced unique index are non-negotiable.
- Reserved list MUST include `u` (the profile prefix) and every other top-level route segment, or a handle could shadow a real route.
- Handle is **not PII** — warehouse-safe; do not add it to any GDPR erasure/anonymise path as sensitive free-text (it is a chosen public identifier).

## Test Audit
COMPACT — this is a backend schema/validation issue; the US-surface (Elm/E2E) layers are #212/#213/#214's.

| Layer | Applies? | Verdict |
|-------|----------|---------|
| DB (schema/index/backfill) | yes | ✅ `accounts_test.exs` describe `"handles (/u/:handle) — #211"`: `get_user_by_handle/1 is case-insensitive and trims` (:103) exercises the `lower(handle)` index path; backfill+NOT-NULL enforced by migration `20260714200500`. |
| Validation logic | yes | ✅ `accounts_test.exs:110` `validate_handle/1 rejects bad format, reserved words, and too-short handles`; `:97` `generate_handle/1 slugifies the name and appends a random suffix` (incl. `nil`→`reader_…` and emoji→`reader_…`). |
| Registration auto-gen | yes | ✅ `accounts_test.exs:78` `register/1 auto-generates a valid, slugified handle from the display name`. |
| Uniqueness (case-insensitive) | yes | ✅ `accounts_test.exs:148` (via #212) `update_profile/2 rejects a handle already taken (case-insensitive)` proves the `lower(handle)` unique constraint fires; reserved-collision via `:110`. |
| API calls | no | n/a — no endpoint in this issue (edit is #212, read is #213). |
| Auth guards | no | n/a — no request surface. |
| Events | no | n/a — US-10.5.1 §6: a handle change reuses `user.profile_updated` (UUID-only payload); no handle enters `event_log`. |
| Oban | no | n/a — US §7. |
| External | no | n/a — US §8. |
| Storage | no | n/a — US §9. |
| Cache | no | n/a — US §10 (direct DB lookup). |
| dbt | yes | ✅ `stg_users.handle` is proto-generated by `mix proto.sync`; `mix proto.sync --check` (CI) guards drift. Handle is warehouse-safe (US §11). |
| Elm state machine | no | n/a — no frontend in this issue (#212 owns the field). |
| op metrics / perf / cost | no | n/a — US §13–15: covered by the settings-endpoint SLO gate; a Neon write only. |

**Visibility variations owned here:** case-insensitive uniqueness (`AdaLovelace` == `adalovelace`),
reserved-word exclusion, format rejection, and the ghost-safe backfill fallback — all asserted above.

Punch list: **0 ❌**. Verdict: **GREEN** — every applicable cell ✅, cited against real tests in `accounts_test.exs` verified by read.

## Definition of Done
- [x] `handle` proto field + migrations + `lower(handle)` unique index + NOT-NULL backfill.
- [x] `generate_handle/1`, `validate_handle/1`, `get_user_by_handle/1`, `ReservedHandles.reserved?/1`.
- [x] Registration auto-generates a handle.
- [x] **Feature-Completeness Pre-Check ✅** for US-10.5.1's schema/validate/auto-gen half.
- [x] Tests written and passing (`accounts_test.exs` describe `"handles (/u/:handle) — #211"`).
- [ ] `just run just verify` passes; `mix proto.sync --check` green.
- [x] **Test audit (above) is GREEN** — 0 ❌, 0 ⚠️.
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`).

## Dependencies
None (foundation for the rest of #210).

## Agent Assignment
elixir-agent.

## Progress Notes
Landed on `feat/210-public-profiles`: proto field 32, both migrations, `ReservedHandles`, and the `Accounts` handle functions with tests.
