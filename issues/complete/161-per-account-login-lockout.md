# Issue #161: Per-account login lockout (real credential-stuffing defence)

## Summary
Add per-account lockout after N failed login attempts. The current per-IP
rate limit alone is a weak credential-stuffing defence — attackers
trivially rotate IPs while legitimate users behind NAT share one — and
should not be the only line of defence.

## User Stories
N/A (platform / security).

## Goal
A targeted attack against a known account (or a credential-stuffing run
that lands enough attempts on the same email) is throttled at the
account level, not just the IP level. Legitimate users hitting a
typo-retry storm aren't affected. Per-IP rate limiting remains in place
as defence-in-depth.

## Scope Check
- One controller (`AuthController.login`).
- Zero new endpoints.
- ~50-150 LOC of production code (counter on `op.users` + check + reset).
- One concern (account lockout). No bundled scope creep.

## Wiring
- [x] Implementation only. Lockout is enforced inside `AuthController.login`;
      no router or UI changes. Wired by this issue.

## Technical Requirements

### Failure-counter columns

Add three columns to `op.users`:

| Column | Type | Default | Purpose |
|--------|------|---------|---------|
| `failed_login_count` | `integer` | `0` | Increments on every failed login (wrong password). Resets to `0` on a successful login. |
| `failed_login_first_at` | `timestamptz` | `NULL` | Timestamp of the first failure in the current run. Used to roll the counter when the failure window has elapsed without further failures. |
| `locked_until` | `timestamptz` | `NULL` | When non-null and in the future, the account is locked. `NULL` = unlocked. |

Set via `mix proto.sync` since `op.users` is proto-generated. Add the
fields to the `User` proto message and run the generator. (See
`issues/complete/142-bootstrap-staging-neon-branch.md` for the
proto-sync workflow.)

### Lockout policy

- **Threshold**: 10 failed attempts in a 10-minute rolling window per
  account (NOT per IP — the whole point is to defend against IP-rotated
  attacks). Configurable via `:core, :login_lockout_threshold` and
  `:core, :login_lockout_window_seconds`.
- **Lockout duration**: 15 minutes on first lockout, doubling on each
  subsequent lockout within 24 hours (15 → 30 → 60 → 120 min cap).
  Configurable via `:core, :login_lockout_duration_seconds` (initial)
  and `:core, :login_lockout_max_duration_seconds` (cap).
- **Reset**: a successful login resets `failed_login_count` to 0 and
  `locked_until` to NULL. The `locked_until` field also auto-clears
  in the controller logic (when `now > locked_until` the row is
  considered unlocked, regardless of whether the column has been
  rewritten — the next successful login or the next failed login will
  rewrite it).
- **Unlock signal**: while locked, return 423 Locked with a
  `retry_after_seconds` body field. Don't leak whether the email
  exists — if the email is unknown, return the same generic
  "invalid_credentials" response we return today (constant-time
  bcrypt against a dummy hash to prevent enumeration timing).

### Auth controller wiring

In `Stacks.Accounts.authenticate/2` (or the equivalent function):

```elixir
def authenticate(email, password) do
  case Repo.get_by(User, email: email) do
    nil ->
      # Constant-time work to prevent email enumeration via timing.
      Argon2.no_user_verify()
      {:error, :invalid_credentials}

    %User{locked_until: locked_at} = user
        when not is_nil(locked_at) ->
      if DateTime.compare(locked_at, DateTime.utc_now()) == :gt do
        {:error, {:locked, DateTime.diff(locked_at, DateTime.utc_now())}}
      else
        # Lock has expired; treat as unlocked + check password.
        check_password(user, password)
      end

    user ->
      check_password(user, password)
  end
end
```

`check_password/2` increments `failed_login_count` on mismatch (and
applies the lockout logic when the threshold is crossed), zeroes it on
success.

### Telemetry

Emit `[:stacks, :auth, :lockout]` when a lockout fires. The SLO gate
already scrapes auth-related metrics; surfacing this as a metric on
the cost dashboard / Axiom lets us spot attack waves quickly.

### Audit log

Insert a row into `audit.audit_log` for each lockout event with:
- `action: "user.locked"`
- `resource_type: "user"`
- `resource_id: user.id`
- `metadata: %{failed_count: N, lock_duration_s: S}` (encrypted via
  `Stacks.Audit.encrypt_metadata/1` — see `audit_log_test.exs` for the
  pattern).

## Reviewer Context

- The `op.users` schema is **proto-generated**. Don't hand-edit the
  schema file — change `proto/persisted.exs` (or wherever the User
  message lives) and run `mix proto.sync`. Migration is auto-generated.
- Argon2 password verification already exists; the constant-time
  enumeration defence (`Argon2.no_user_verify/0` for the no-user
  case) is in `Stacks.Accounts.authenticate/2`. Don't remove it.
- Per-IP rate limiting on the `:auth` bucket stays in place. This
  issue is layered on top, not a replacement.
- The audit metadata field is encrypted via Cloak (see
  `Stacks.Vault`). Reuse the existing helper, don't write a new one.

## Definition of Done

- [ ] `op.users` has `failed_login_count`, `failed_login_first_at`,
      `locked_until` columns (proto-synced).
- [ ] `Stacks.Accounts.authenticate/2` checks `locked_until` first and
      returns `{:error, {:locked, retry_after_seconds}}` when the
      account is locked.
- [ ] Failed-login counter increments on bad password, resets on
      successful login.
- [ ] Threshold + window + duration are all `Application.get_env`
      readable so prod / staging / preview can tune independently.
- [ ] Locked accounts return HTTP 423 with `retry_after_seconds` in
      the body. Unknown email returns the same generic
      `invalid_credentials` response (no enumeration signal).
- [ ] `[:stacks, :auth, :lockout]` telemetry event fires on each
      lockout. Tagged with `user_id` (NOT email — that's PII; user_id
      is the canonical aggregate).
- [ ] `audit.audit_log` row inserted on each lockout, metadata
      Cloak-encrypted.
- [ ] Tests cover: threshold trip, threshold reset on success,
      lockout expiry, repeated-lockout doubling, no enumeration via
      timing or response shape, telemetry + audit emission.
- [ ] `just verify` passes.

## Dependencies

- None. The current per-IP rate limiting in
  `StacksWeb.Plugs.RateLimiter` (the `:auth` bucket) stays in place
  alongside this.

## Progress Notes

2026-04-29: Filed as a follow-up to the rate-limiter-default bump
(`apps/core/lib/stacks_web/plugs/rate_limiter.ex` moduledoc explicitly
calls this out as the proper fix). The bump from 5/60s to 60/60s on
the `:auth` bucket made room for legit NAT users while keeping a
floor against scripted attempts; this issue replaces "floor" with
"actual ceiling".
