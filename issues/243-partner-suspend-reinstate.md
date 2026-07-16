# Issue #243: Partner suspend / reinstate (+ status-vocabulary reconciliation)

## Summary
Give the platform owner a suspend/reinstate control over a whole partner: suspending hides **all**
their content (inventory, events, third-space listings) from every reader surface **and** rejects
their API-key calls until reinstated. Delivering this first requires reconciling the partner `status`
vocabulary drift — the spec (`docs/technical-architecture.md:1314-1323`) mandates
`ENUM('pending','active','suspended')` while the code and proto use the free string
`pending/approved/rejected` — so this issue also lands the status migration (map `approved`→`active`,
add `suspended`) that the rest of §9.6 builds on.

**Domain:** partner-integration (§9). **DEFERRED — not part of the current #118+#231 PR.** Design/backlog.

## User Stories
US-9.6.1 (Platform Owner Reviews Partner Content) — point 4: *"The owner can suspend a partner
entirely, which hides all their content and revokes API access until reinstated."*
Spec: `docs/user-stories.md:288`; partner-status enum `docs/technical-architecture.md:1314-1323`.

## Goal
An owner (MFA admin session) can `PUT /api/partners/:id/suspend` and `PUT /api/partners/:id/reinstate`.
A suspended partner's API key is rejected at the auth boundary (401/403), and none of their inventory,
events, or third-space listings appear on any reader surface. Reinstating restores both. The `status`
column has a single, spec-aligned vocabulary with a DB-level constraint.

## Scope Check
<!-- ≤3 controllers, ≤2 new endpoints, ~300 LOC. -->
- Controllers: `PartnerController` only (add `suspend`/`reinstate` actions). **1 controller.** ✅
- New endpoints: `PUT /api/partners/:id/suspend`, `PUT /api/partners/:id/reinstate`. **2 endpoints.** ✅
- LOC: migration + proto sync + context fns (`suspend_partner/2`, `reinstate_partner/2`) + auth-plug
  gate + reader-surface filter. Borderline ~300 — **the status-enum migration is a distinct concern**
  from the suspend/reinstate behaviour. If the migration + call-site sweep exceeds budget on its own,
  split it into a **#243a "partner status-enum reconciliation"** prerequisite and keep suspend/reinstate
  in #243. Note the split here; decide at pickup.
- Mixed concerns? The migration is a hard prerequisite of the behaviour (can't gate on `suspended` that
  doesn't exist), so they are coupled — kept together with the split escape-hatch above.

## Wiring
- [x] This issue includes router wiring and is user-facing (owner-facing) when complete.
- [ ] Implementation only.

## Status-vocabulary reconciliation (load-bearing — resolve FIRST)
This is the blocking prerequisite and MUST be captured in this issue.

| Source | Current values | Location |
|--------|----------------|----------|
| Spec (canonical) | `pending` / `active` / `suspended` | `docs/technical-architecture.md:1314-1323` |
| Ecto schema (free string, no constraint) | `pending` / `approved` / `rejected` | `apps/core/lib/stacks/gen/partners/partner.ex:20` |
| Proto (drives schema + comment) | comment says `pending, approved, rejected` | `proto/stacks/internal/v1/partner.proto:26` (`status = 6`) |
| Context call sites | writes `"approved"`/`"rejected"`, gates auth on `== "approved"` | `apps/core/lib/stacks/partners.ex:31,55,66,91,107,133,152` |

**Resolution (mandated mapping):**
1. Adopt the spec vocabulary. Map existing `approved` → `active`; **add** `suspended`.
2. **Keep `rejected`** as a distinct fourth lifecycle value — it is a real, already-emitted state
   (`reject_partner/3`, US-9.7.1 "Declined") that the spec's 3-value enum omits. Flag this as a spec
   gap: target vocabulary is `pending` / `active` / `suspended` / `rejected`. (Do **not** silently
   collapse `rejected` into `suspended` — reject = never-approved, suspend = approved-then-revoked.)
3. Migration: backfill `UPDATE op.partners SET status='active' WHERE status='approved'` and add a
   `CHECK (status IN ('pending','active','suspended','rejected'))` constraint (Postgres CHECK, not a
   native enum — additive, reversible, matches the free-string column already in place).
4. Update the proto comment + run `mix proto.sync` (regenerates `partner.ex` + dbt `stg_partners` +
   ProtoJSON) — do NOT hand-edit the generated schema (MEMORY: proto-generated, 30 op.* tables).
5. Sweep every `"approved"` literal in `partners.ex`: `partner_changeset` default stays `pending`;
   `approve_partner` writes `"active"` and its already-approved guard matches `"active"`;
   `authenticate_partner` query `p.status == "approved"` → `== "active"`; `rotate_key` guard
   `status != "approved"` → `!= "active"`. Reader surfaces (below) filter on `status == "active"`.
6. Migration-safety: this touches a migration + Ecto schema → run the **migration-safety** standard;
   no PII change so the gdpr-review lens is a quick confirm (status is not personal data).

## Feature-Completeness Pre-Check
<!-- NEW feature — the happy path does not exist yet. -->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-9.6.1 pt 4 — suspend/reinstate a partner | No `suspend_partner`/`reinstate_partner` fn; no route; auth plug has no status gate; reader surfaces don't filter on partner status | ⬜ to verify at pickup | ❌ MISSING | **Build in-scope** (this issue). |

Verdict: ❌ missing — built by this issue.

## Technical Requirements
### 1. Status migration + call-site sweep
- As enumerated in "Status-vocabulary reconciliation" above. This is phase 1 and blocks everything else.

### 2. Context: `Stacks.Partners`
- `suspend_partner(partner_id, admin_id)` — sets `status: "suspended"`, records who/when (reuse
  `approved_by_id`/`approved_at` or add `suspended_by_id`/`suspended_at` — prefer the latter for
  auditability; add the proto fields + `mix proto.sync`). Emits `partner.suspended`
  (`Events.emit_safe`, `aggregate_type: "partner"`) — payload MUST NOT include partner PII (contact
  email); id + admin id only. Returns `{:ok, Partner}` / `{:error, :not_found | :not_active}`.
- `reinstate_partner(partner_id, admin_id)` — `suspended` → `active`; emits `partner.reinstated`.
- Both are idempotent-guarded (suspending a suspended partner → `{:error, :already_suspended}`).

### 3. API-key rejection at the boundary
- `authenticate_partner/1` already scopes to `status == "active"` after the sweep, so a suspended
  partner's key fails to match → `{:error, :invalid}` → `PartnerAuthPlug`
  (`stacks_web/plugs/partner_auth_plug.ex:14`) returns 401. **Add an explicit test** that a previously
  valid key returns 401 after suspension. Consider a distinct 403 + `{error: "partner_suspended"}`
  body (vs 401 invalid) so a suspended partner gets an actionable message — decide at design; either
  way the call is rejected.

### 4. Hide all content from reader surfaces
- Every reader-facing read of partner-owned data MUST exclude suspended partners:
  - Partner inventory joins that power US-9.8.1 "Available Locally" (book-detail overlay) — filter
    `partners.status == "active"`.
  - Third-space events (`list_partner_events`, discovery/event surfaces) — exclude events whose owning
    partner/third-space is suspended.
  - Third-space listings on the map. Enumerate the exact query sites at pickup (grep
    `partner_inventory`, `third_space_event`, `ThirdSpace` reader queries) and add the status filter to
    each. This is the "hides ALL their content" clause — a missed surface is a leak.

### 5. Owner endpoints
- `PUT /api/partners/:id/suspend`, `PUT /api/partners/:id/reinstate` in the MFA-admin scope
  (`core_web/router.ex:306-315`, alongside `approve`/`reject`). Return the updated partner
  (`ProtoJSON.partner/1`). The partner-management table (US-9.6.1 "what they see") consumes the new
  `active/suspended/pending` status — surface it there.

## Reviewer Context
- Partner status is a **free string** today with no DB constraint; the proto is the source of truth and
  regenerates the Ecto schema — never hand-edit `apps/core/lib/stacks/gen/partners/partner.ex`.
- `authenticate_partner/1` is O(n) over active partners by prefix (partners.ex:125) — suspending
  removes a partner from that scan, which is the enforcement mechanism; keep that invariant.
- Admin routes require an MFA-verified admin session (`core_web/router.ex:306`); partner API routes use
  `PartnerAuthPlug` (API key). Suspend/reinstate are owner actions → admin scope.
- Event payloads must stay PII-free (event_log is immutable; gdpr-review lens).

## Test Audit
_Baseline — backlog issue, nothing built yet. Load-bearing: the migration/backfill, auth rejection, and
the "all content hidden" invariant._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Migration + backfill (`approved`→`active`, CHECK constraint) | yes | ❌ (→ ✅ migration test: existing `approved` rows become `active`; illegal status rejected) |
| Context: suspend/reinstate state transitions + guards | yes | ❌ (→ ✅ partners_test: pending/active/suspended transitions + idempotency errors) |
| Auth boundary rejects suspended key | yes | ❌ (→ ✅ plug/controller test: valid key → 401/403 after suspend, restored after reinstate) |
| Reader-surface hiding (inventory + events + spaces) | yes | ❌ (→ ✅ per-surface test: suspended partner's rows absent; reinstated → present) |
| Event flow (`partner.suspended`/`partner.reinstated`, PII-free) | yes | ❌ (→ ✅ event emitted, payload has no contact_email) |
| dbt `stg_partners` accepts new status values | yes | ❌ (→ ✅ accepted_values schema test after `mix proto.sync`) |
| Owner endpoints (route + ProtoJSON shape) | yes | ❌ (→ ✅ controller test: 200 + updated status; 404; MFA-guard) |
| Elm owner UI (partner-management table status) | yes | ❌ (→ ✅ Elm test for status rendering) or n/a if UI deferred to a wiring issue |
| 11/12 metrics/perf | partial | n/a — covered by SLO gate; add a suspend/reinstate counter if the §9.6 dashboard tracks it |

Punch: (1) status migration + backfill + CHECK + proto.sync; (2) call-site sweep of `"approved"`;
(3) suspend/reinstate context fns + events; (4) auth-plug rejection test; (5) reader-surface status
filters (enumerate every site); (6) owner endpoints + router; (7) dbt accepted_values; (8) owner UI.
Verdict: baseline — 8 punch items.

## Definition of Done
- [ ] Status vocabulary reconciled to spec: `approved`→`active` backfilled, `suspended` added, `rejected`
      preserved, CHECK constraint in place, proto comment updated + `mix proto.sync` re-run.
- [ ] Every `"approved"` literal in `partners.ex` swept to `"active"`; `authenticate_partner` gates on
      `active`.
- [ ] `PUT /api/partners/:id/suspend` + `/reinstate` (MFA-admin scope) work end-to-end and return the
      updated partner.
- [ ] A suspended partner's API key is rejected (401/403) and restored on reinstate — tested.
- [ ] A suspended partner's inventory, events, and third-space listings are absent from every enumerated
      reader surface; restored on reinstate — tested per surface.
- [ ] `partner.suspended` / `partner.reinstated` emitted, PII-free.
- [ ] **Feature-Completeness Pre-Check is ✅** — suspend/reinstate driven live on a local stack.
- [ ] `just verify` passes; test audit GREEN; migration-safety + gdpr-review lenses applied.
- [ ] Meets the Completion Bar.

## Dependencies
- **Foundational for §9.6** — the status-enum reconciliation here unblocks #244 (flag/takedown) and
  #245 (moderation queue). Depends on the **status-enum migration** it lands in phase 1 (or on split-out
  **#243a** if the Scope Check split is taken).
- Reader-surface hiding intersects US-9.8.1 (Available Locally) — reuse the same partner-inventory join.

## Agent Assignment
elixir-agent (migration + context + auth + reader-surface filters), with `mix proto.sync` regen.
Reviewers: elixir-reviewer + platform-reviewer; migration-safety + gdpr-review lenses. Owner-UI (Elm)
row via elm-agent if wired in-scope.

## Progress Notes
[Updated by agents during execution.]
