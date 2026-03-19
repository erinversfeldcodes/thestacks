# Issue #069: KYC Age Verification Integration — Registration Flow

## Summary
Implement age verification at registration via Smile Identity (primary), with config flag `REQUIRE_KYC` (false in dev, true in production). Covers the HTTP client, registration flow state machine, webhook/callback handler, `kyc_status` column on `users`, and the Elm KYC step in the registration UI.

## User Stories
US-4.1.2 (KYC / age verification without full identity disclosure)

## Goal
When `REQUIRE_KYC=true`, a new user cannot access the platform until age verification is complete. The registration flow is: register → KYC redirect (Smile Identity hosted flow) → callback → account activated. When `REQUIRE_KYC=false` (dev/test), the KYC step is skipped and the account activates immediately.

## Technical Requirements

**Migration:**
- Add `kyc_status ENUM('unverified', 'pending', 'approved', 'rejected', 'bypassed') DEFAULT 'unverified'` to `op.users`
- Add `kyc_session_id TEXT NULL` (Smile Identity session reference)
- Add `kyc_completed_at TIMESTAMPTZ NULL`

**`Stacks.Accounts` context updates:**
- `register/1` — if `REQUIRE_KYC=true`: set `kyc_status = 'pending'`, generate a Smile Identity session, return `{:ok, :kyc_required, kyc_url}` instead of JWT. If `REQUIRE_KYC=false`: set `kyc_status = 'bypassed'`, return JWT as normal.
- `authenticate/2` — if `kyc_status` is not `approved` or `bypassed`, return `{:error, :kyc_pending}` with no JWT
- `complete_kyc/2` — called by the webhook handler; sets `kyc_status = 'approved'` or `'rejected'`, emits `user.kyc_completed` event

**`Stacks.Accounts.SmileClient` (new):**
- `create_session/1` — POST to Smile Identity API to create a verification session; returns `session_id` + redirect URL
- `verify_callback/1` — validate webhook HMAC signature; parse result payload
- Config: `SMILE_API_KEY`, `SMILE_CALLBACK_SECRET`, `KYC_PROVIDER` env var (currently `smile_identity`; abstracted for future provider swap)
- Circuit breaker: `Fuse.install(:smile_identity, ...)`

**`StacksWeb.AuthController` updates:**
- `register/2` — handle `{:ok, :kyc_required, kyc_url}` response; return `{kyc_url: "..."}` to frontend so Elm redirects user
- `GET /api/auth/kyc/callback` — Smile Identity redirects here post-verification; validates session, calls `complete_kyc/2`, issues JWT if approved

**`StacksWeb.WebhookController.smile/2` (new route):**
- `POST /api/webhooks/smile` — async confirmation; verifies HMAC, calls `complete_kyc/2`
- Idempotent: re-processing same `session_id` is a no-op

**Elm registration UI (small addition — scoped to this issue):**
- After `POST /api/auth/register` returns `{kyc_url: "..."}`: show "Verifying your age…" screen with a "Continue to verification" button that opens `kyc_url` in the same tab
- After Smile redirect back: Elm detects `/auth/kyc/callback` route, polls `GET /api/auth/me` for `kyc_status`, shows success or rejection message
- On rejection: clear message "We weren't able to verify your age. Contact support." (no detail on failure reason — no PII leakage)

**Events emitted:**
- `user.kyc_completed` (payload: `{user_id, status: "approved" | "rejected", provider: "smile_identity"}`)

**Rate limiting:**
- Max 3 KYC attempts per user per 24h (prevents replay abuse)

## Definition of Done
- [ ] `kyc_status`, `kyc_session_id`, `kyc_completed_at` columns on `users`
- [ ] `REQUIRE_KYC=false` skips KYC entirely; registration returns JWT as before
- [ ] `REQUIRE_KYC=true` blocks JWT until `kyc_status = 'approved'`
- [ ] Smile Identity session creation works (mocked in test)
- [ ] Webhook callback validates HMAC; updates `kyc_status`
- [ ] `authenticate/2` rejects `kyc_status = 'pending'` with `{:error, :kyc_pending}`
- [ ] Elm registration shows KYC redirect; handles approved and rejected outcomes
- [ ] `user.kyc_completed` event emitted to event_log
- [ ] Rate limit: 3 attempts / user / 24h
- [ ] `mix test` passes with mocked Smile Identity
- [ ] `mix sobelow` passes (no auth bypass paths)
- [ ] `ruff check` passes if any Python test harness changes

## Dependencies
Issue #043 (users table must exist for kyc_status migration)

## Agent Assignment
elixir-agent (Opus — auth state machine, webhook security) + elm-agent (KYC redirect step)

## Progress Notes
<!-- Updated by agents during execution -->
Scheduled end of Wave A. Human (Erin) available to assist with Smile Identity credentials and sandbox account in approximately 2 hours from 2026-03-19.
