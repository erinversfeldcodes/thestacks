# Issue #237: Auth & session security metrics + dashboard

> **Wave 2 of the #231 observability initiative — DEFERRED.** Do not start until the current
> #118 + #231 epic ships its PR.

## Summary
The security-critical auth signals are **uninstrumented**: no counter fires when a rotated
refresh token is **reused/replayed** (token theft — `guardian.ex` emits nothing), when a session hits
the **absolute lifetime cap** (`auth_controller.ex` returns `session_expired` silently), or on **MFA
verify** success/failure (`mfa.ex` emits nothing). Registration, login-failure, JWT-issuance, and
refresh-revoke-failure are already wired (#181/#206). Close the security gaps and dashboard the auth
lifecycle.

## User Stories
None — security observability of the auth/session system (US-14.x). Child of epic **#231** (Wave 2).

## Goal
Token-reuse detection, session-cap hits, and MFA verify outcomes are counted, exported, and on an
auth-security dashboard whose panels teach; a live-exposure test proves each appears after the
triggering interaction (replay a rotated token → reuse counter; exceed the cap → cap counter; fail MFA
→ MFA-fail counter).

## Scope Check
- >3 controllers? No (guardian + auth_controller + mfa + PromEx + dashboard). >2 endpoints? No. >300
  LOC? No (3 emit sites + registrations + JSON + tests). Mixed concerns? No — auth-security observability.

## Wiring
- [x] Ops-facing (Grafana via #232). Delivers emit + export + dashboard + validation.

## Feature-Completeness Pre-Check
n/a — no user story. The auth *behaviour* (rotation/reuse gate in `auth_token_family.ex` + `guardian.ex`,
the 7-day cap at `auth_controller.ex:342`, MFA in `mfa.ex`) is BUILT; this adds observation only.

## Technical Requirements

### 1. Wire the missing emits (whitelisted-atom metadata, NO PII — never a token/email/user-id as a tag)
- **Refresh-reuse / rotation-race detected** — at the reuse gate in `guardian.ex` (the family-burn path
  referenced at `guardian.ex:47/69/72` + `auth_token_family.ex`): emit `[:stacks, :auth, :refresh, :reuse_detected]`
  when a replayed/rotated token is caught and its family revoked. *This is the token-theft signal.*
- **Session lifetime-cap hit** — at `auth_controller.ex:288/342` where the absolute 7-day cap returns
  `session_expired`: emit `[:stacks, :auth, :session, :expired]` (tag `reason: :lifetime_cap`).
- **MFA verify** — in `mfa.ex` / `plugs/require_mfa.ex`: emit `[:stacks, :auth, :mfa, :verify]`
  (tag `outcome: :success | :failure`).

### 2. Register the three new families in `apps/core/lib/core/prom_ex/plugins/stacks.ex` (mirror the existing auth counters at ~:170–:201).

### 3. Dashboard (`apps/core/priv/grafana/auth_security.json` via `dashboards/0`), teaching panels:
- **Refresh-reuse detected** — *any non-zero value is a replayed refresh token (possible theft); investigate the user + burned family.* (alert-worthy.)
- **Login failures by `type`** (401/403/422/429) + **registration** success/fail — *brute-force / lockout / rate-limit-on-auth signals.*
- **JWT issued by `context`** (login vs refresh) — *refresh-to-login ratio; a refresh collapse → the interceptor is failing.*
- **Refresh-revoke failures** (existing #181 counter) — *old tokens left live past rotation.*
- **Session-cap hits** — *how often users are force-logged-out by the 7-day cap → re-login spikes.*
- **MFA verify** success vs failure — *admin brute-force / MFA friction.*

### 4. Drift + live-exposure tests (per #230)
- Drift: dashboard ↔ registered families; every new family has a panel.
- Live-exposure: replay a rotated refresh token (reuse), drive a capped session to expiry, and fail an
  MFA verify, then assert `GET /internal/metrics` shows `stacks_auth_refresh_reuse_detected_*`,
  `stacks_auth_session_expired_*`, `stacks_auth_mfa_verify_*` with samples.

## Reviewer Context
- **Security-sensitive:** the reuse-detected counter is an alerting signal — get its placement exactly
  on the family-burn branch (coordinate with `auth_token_family.ex`'s rotation logic).
- No PII in tags (GDPR); the reuse event must not log/tag the token value.
- Existing auth counters (registration/jwt/login_failure/revoke_failed) are done (#181/#206) — reuse,
  cap, MFA are the net-new work.

## Test Audit
_Compact — observability + 3 new security emits._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Emit (reuse / session-cap / MFA) | yes | ❌ `guardian.ex`, `auth_controller.ex` cap path, `mfa.ex` emit nothing. (→ ✅, firing tests) |
| Metrics exported | yes | ❌ the 3 families unregistered. (→ ✅) |
| Dashboard + teaching panels | yes | ❌ no auth dashboard. (→ ✅) |
| Drift + live-exposure | yes | ❌ (→ ✅) |
| 1–10,12,13 | no | n/a — auth behaviour already tested (#124/#178/#179/#180). |

Punch: (1) 3 emits + firing tests; (2) register; (3) dashboard; (4) drift; (5) live-exposure.
Verdict: baseline — 5 punch items; the reuse-detected counter is the highest-value (security).

## Definition of Done
- [ ] Refresh-reuse-detected, session-cap, and MFA-verify emits wired with firing tests (happy + sad).
- [ ] The three families registered + exported at `/internal/metrics`.
- [ ] `auth_security` dashboard registered, every panel teaching; reuse-detected panel flagged alert-worthy.
- [ ] Drift + live-exposure tests (each metric appears after its triggering interaction).
- [ ] `just verify` passes; test audit GREEN; no PII in tags (GDPR-reviewed).
- [ ] Meets the Completion Bar.

## Dependencies
#178/#179/#180 (session behaviour — merged). **Deferred: start after the current #118+#231 PR.**

## Agent Assignment
elixir-agent (auth emits + PromEx + dashboard + tests). Reviewer: elixir-reviewer + platform-reviewer
(+ a security lens on the reuse-detected placement).
