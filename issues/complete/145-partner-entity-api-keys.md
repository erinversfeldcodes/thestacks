# Issue #145: Partner Entity & API Key Management

## Summary
Introduce the `Partner` schema, registration workflow, platform-owner approval queue, and HMAC-based API key lifecycle. Partners (bookshops, cafes, reading groups) are the supply side of the Third Spaces and inventory features. This is the prerequisite for all partner-facing APIs.

## User Stories
US-9.1.1 Partner Registration, US-9.1.2 API Key Management

## Goal
A partner can self-register with their business information. The platform owner can approve or reject the application. Approved partners receive a HMAC secret used to authenticate all subsequent API requests. Partners can rotate their key.

## Scope Check
- Does this issue touch more than 3 controllers? → No — `PartnerController` (admin), `PartnerRegistrationController` (public).
- Does this issue add more than 2 new endpoints? → Yes (5 endpoints) — all within partner registration domain.
- Does this issue exceed ~300 lines of production code? → Migration + context ~200 LOC, controllers ~100 LOC.
- Does this issue combine unrelated concerns? → No.

## Wiring
- [x] This issue includes router wiring and is user-facing when complete.

## Technical Requirements

**Migration:** Add `op.partners` table:
```sql
id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
name            text NOT NULL,
business_type   text NOT NULL,  -- 'bookshop' | 'cafe' | 'reading_group' | 'other'
contact_email   text NOT NULL UNIQUE,
website_url     text,
status          text NOT NULL DEFAULT 'pending',  -- 'pending' | 'approved' | 'rejected'
hmac_secret     text,           -- NULL until approved; Argon2-hashed
api_key_prefix  text,           -- first 8 chars of raw key for display
approved_by_id  uuid REFERENCES op.users(id),
approved_at     timestamptz,
created_at      timestamptz NOT NULL DEFAULT now(),
updated_at      timestamptz NOT NULL DEFAULT now()
```

**Proto:** Add `Partner` message to `proto/stacks/internal/v1/partner.proto`. Run `mix proto.sync`.

**`Stacks.Partners` context:**
```elixir
register_partner(attrs)           # → {:ok, Partner} | {:error, changeset}
approve_partner(partner_id, admin_id)
  # generates HMAC secret, stores Argon2 hash, returns raw key ONCE
  # → {:ok, {Partner, raw_key}} | {:error, :not_found | :already_approved}
reject_partner(partner_id, admin_id, reason)  # → {:ok, Partner}
rotate_key(partner_id)            # → {:ok, raw_key} | {:error, :not_found}
authenticate_partner(raw_key)     # → {:ok, Partner} | {:error, :invalid}
list_pending_partners()           # → [Partner]
```

**HMAC key format:** `sk_partner_<40 random hex chars>`. Store `Argon2.hash_pwd_salt(raw_key)` in `hmac_secret`. `api_key_prefix` stores first 8 chars for display ("sk_partn…").

**`PartnerRegistrationController`** (no auth required):
- `POST /api/partners/register` → 201 (registration received) or 422

**`PartnerController`** (platform owner only, add `:platform_owner` Guardian role check):
- `GET /api/admin/partners?status=pending` → list pending applications
- `PUT /api/admin/partners/:id/approve` → returns `{ data: { api_key: "sk_partner_..." } }` — key shown once
- `PUT /api/admin/partners/:id/reject`

**Partner auth plug** (`StacksWeb.PartnerAuthPlug`):
- Reads `Authorization: Bearer sk_partner_...` header
- Calls `Partners.authenticate_partner/1`
- Sets `conn.assigns[:current_partner]`

## Reviewer Context
- Follow `Stacks.Auth` Argon2 pattern for hashing the API key.
- The raw key is returned **once** on approve — never stored in plaintext, not recoverable. Document this in the approval response.
- `platform_owner` role check: the platform owner user has a special role flag. Check `user.role == "platform_owner"` in the Guardian pipeline.
- `mix proto.sync` must be run after adding the proto message.

## Definition of Done
- [ ] `approve_partner/2` returns raw key exactly once; subsequent calls to `authenticate_partner/1` work
- [ ] `rotate_key/1` invalidates the old key immediately
- [ ] `PartnerAuthPlug` returns 401 for missing/invalid keys
- [ ] Platform owner approval endpoint returns 403 for non-owner callers
- [ ] `list_pending_partners/0` is accessible only to platform owner
- [ ] Tests cover: registration, approval + key use, rotation, rejection, invalid key auth
- [ ] `just verify` passes

## Dependencies
None.

## Agent Assignment
elixir-agent

## Progress Notes
