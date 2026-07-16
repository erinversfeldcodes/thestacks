# Issue #247: Partner profile self-service update + name/address re-approval

## Summary
Give an authenticated partner a self-service surface to edit their business details (US-9.7.2). Changes
to **non-sensitive** fields (description, operating hours, website URL) take effect immediately; changes
to **name** and **physical address** do NOT go live — they route into the owner moderation queue (#245)
for re-approval, with the previously approved value still shown publicly until the owner signs off. The
partner self-service update surface does not exist yet.

**Domain:** partner-integration (§9). **DEFERRED — not part of the current #118+#231 PR.** Design/backlog.

## User Stories
US-9.7.2 (Partner Profile Self-Service Update). Spec: `docs/user-stories.md:330-344`.
- pt 3: *"Changes take effect immediately for non-sensitive fields (description, hours, website)."*
- pt 4: *"Name and address changes require platform owner re-approval (flagged in the owner's moderation
  queue)."*

## Goal
`PUT /api/partner/profile` (partner-API-key auth) lets a partner update their own profile. Non-sensitive
fields persist and go live immediately. Name/address changes are stored as a **pending change** that
appears in the #245 moderation queue; the public/reader-facing value stays the last-approved one until
the owner approves the pending change (approve → apply; remove → discard).

## Scope Check
- Controllers: one new `PartnerProfileController` (show current + update). **1 controller.** ✅
- New endpoints: `GET /api/partner/profile`, `PUT /api/partner/profile`. **2 endpoints.** ✅
- LOC: profile update context fn (split non-sensitive vs sensitive) + pending-change storage +
  queue integration + serializer. Borderline ~300. The **pending-change model** (how a name/address
  change is held) is the subtle part — if it needs its own table/migration + proto sync it may push
  over budget → split the pending-change plumbing into **#247a** and keep the immediate-update path in
  #247. Note the split; decide at pickup.
- Mixed concerns? Immediate update + deferred re-approval are one concern (profile self-service). ✅

## Wiring
- [x] This issue includes router wiring and is user-facing (partner-facing) when complete.
- [ ] Implementation only.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-9.7.2 pts 1-3 — partner edits non-sensitive fields, live immediately | No partner-profile update route/controller; `Partners` has `register_partner`/`partner_changeset` but no self-service update; partner dashboard edit surface absent | ⬜ to verify at pickup | ❌ MISSING | **Build in-scope** (this issue). |
| US-9.7.2 pt 4 — name/address change routes to owner re-approval queue | No pending-change model; nothing writes to the #245 queue from a partner edit | ⬜ to verify at pickup | ❌ MISSING | **Build in-scope** (this issue; depends on #245). |

Verdict: ❌ missing — built by this issue.

## Technical Requirements
### 1. Partner-authenticated profile endpoints
- `GET /api/partner/profile` and `PUT /api/partner/profile` under the existing partner-API scope
  (`core_web/router.ex:319`, `pipe_through [:api, :partner_auth]`) — `conn.assigns[:current_partner]` is
  the acting partner (`PartnerAuthPlug`). A partner can only ever edit **their own** profile (the plug
  scopes to the authenticated partner — no `:id` in the path).

### 2. Split fields: immediate vs re-approval
- **Immediate (non-sensitive):** `description`, operating hours, `website_url` (and logo, if the asset
  pipeline exists — else defer logo to a follow-up). Validate + `Repo.update` the `partners` row; live at
  once. Run the **#246 `ContentPolicy`** text check on `description` (reuse, don't re-implement).
- **Re-approval (sensitive):** `name`, physical address. These MUST NOT mutate the live `partners` row.
  Store the proposed value as a **pending change** and write a moderation-queue entry
  (`op.partner_content_flags` with `content_type: "profile_change"` or a dedicated pending-change table —
  decide with #244/#245 to avoid schema drift). The public value = last-approved until owner acts.
- `Partners.update_profile(partner, attrs)` partitions the attrs, applies the immediate ones, and
  enqueues the sensitive ones for re-approval; returns `{:ok, %{applied: [...], pending: [...]}}`.

### 3. Owner re-approval via the #245 queue
- The pending name/address change appears in `GET /api/partners/flags` (#245) as a
  `source: "self_service"` (or `"profile_change"`) entry. **Approve** applies the pending value to the
  live `partners` row (name → possibly re-runs the name-uniqueness/relevance check); **remove** discards
  it. Extend #245's `approve_flag`/`remove_flag` (or add a small `apply_pending_change` disposition) to
  handle the "apply the stored value" case — coordinate the disposition semantics with #245.
- Because name is part of the partner's public identity, an approved name change may need to re-emit a
  `partner.profile_updated` event so reader surfaces/caches refresh (event-driven; PII-free payload).

### 4. Public value stays last-approved
- Reader-facing partner reads must show the **approved** name/address, never the pending one, until the
  owner approves. If using a pending-change table, reader reads are unchanged (they read the live row);
  if storing pending on the partner row, guard reader reads to the approved columns. Prefer the former.

## Reviewer Context
- **Depends on #245** (moderation queue) for the re-approval routing — this issue writes the pending
  name/address change into that queue and extends its disposition to "apply the stored value". Build the
  pending-change model in coordination with #244/#245's `partner_content_flags` to avoid a parallel
  schema.
- Partner auth is API-key based (`PartnerAuthPlug`), scoped to `current_partner` — there is no
  cross-partner edit surface; do not add an `:id` param.
- `description` free text must pass the **#246** ContentPolicy check — reuse it; do not fork the rules.
- Proto-generated `Partner` schema (never hand-edit `gen/partners/partner.ex`); any new pending-change
  fields/table go through the proto + `mix proto.sync` + `persisted.exs`.
- Partner business details are the **partner's** data, not a platform user's PII — but route through
  gdpr-review to confirm the pending-change store isn't accidentally pulled into user export/erasure.

## Test Audit
_Baseline — backlog issue. Load-bearing: the immediate/deferred field split and "public value stays
last-approved until owner acts"._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Field partitioning (immediate vs re-approval) | yes | ❌ (→ ✅ partners_test: description/hours/website apply now; name/address do not mutate live row) |
| Pending-change → #245 queue entry | yes | ❌ (→ ✅ name change creates a queue entry; live row unchanged) |
| Owner disposition applies/discards pending change | yes | ❌ (→ ✅ approve applies value to live row; remove discards) |
| Public value = last-approved until approval | yes | ❌ (→ ✅ reader read shows old name while pending) |
| ContentPolicy on description (reuse #246) | yes | ❌ (→ ✅ violating description → 422, reusing #246) |
| Partner-scoped auth (no cross-partner edit) | yes | ❌ (→ ✅ partner can only edit own profile; auth plug scope) |
| Endpoints (GET/PUT shape + partner-auth guard) | yes | ❌ (→ ✅ controller test: 200 GET, 200 PUT partitioned result, 401 no key) |
| Event (`partner.profile_updated` on approved change, PII-free) | yes | ❌ (→ ✅ emitted on approval) |
| Elm partner-profile form + live preview | yes | ❌ (→ ✅ Elm test) or n/a if UI deferred to a wiring issue |
| 11/12 metrics/perf | partial | n/a — SLO gate |

Punch: (1) partition + immediate update; (2) pending-change model coordinated with #244/#245;
(3) queue entry + owner disposition applies/discards; (4) reader shows last-approved; (5) reuse #246
ContentPolicy; (6) partner-scoped endpoints; (7) profile-updated event; (8) partner-profile UI.
Verdict: baseline — 8 punch items.

## Definition of Done
- [ ] `GET/PUT /api/partner/profile` (partner-auth, own-profile-only) work end-to-end.
- [ ] Non-sensitive fields (description/hours/website) apply immediately; `description` passes #246's
      ContentPolicy.
- [ ] Name/address changes do NOT mutate the live row — they create a re-approval entry in #245's queue;
      the public value stays last-approved until the owner approves.
- [ ] Owner approve applies the pending value (re-emitting `partner.profile_updated`); remove discards it.
- [ ] **Feature-Completeness Pre-Check is ✅** for both rows — immediate edit and deferred name/address
      re-approval driven live locally.
- [ ] `just verify` passes; test audit GREEN; gdpr-review lens on the pending-change store.
- [ ] Meets the Completion Bar.

## Dependencies
- **Depends on #245** (content moderation queue) — name/address changes route into it; requires #245's
  disposition to apply a stored pending value.
- Reuses **#246** (`ContentPolicy`) for the description text check.
- Coordinates its pending-change model with **#244** (`partner_content_flags`) to avoid schema drift.
- Builds on **#243**'s reconciled partner status (an active partner self-services; suspended cannot).

## Agent Assignment
elixir-agent (profile context + partition + pending-change + endpoints), coordinating with #245's
disposition layer. Reviewers: elixir-reviewer + platform-reviewer; gdpr-review lens. Partner-profile UI
(Elm) via elm-agent if wired in-scope.

## Progress Notes
[Updated by agents during execution.]
