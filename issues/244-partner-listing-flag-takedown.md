# Issue #244: Owner flag / takedown of an individual partner listing

## Summary
Give the platform owner a scalpel (vs #243's whole-partner sledgehammer): flag a **single** partner
listing — one inventory item, one event, or one third-space listing — for removal. Flagging immediately
hides that one item from every reader surface and notifies the owning partner, without touching the rest
of the partner's content or their API access. This introduces the `partner_content_flags` record that
the #245 moderation queue reads.

**Domain:** partner-integration (§9). **DEFERRED — not part of the current #118+#231 PR.** Design/backlog.

## User Stories
US-9.6.1 (Platform Owner Reviews Partner Content) — point 3: *"The owner can flag any partner listing
(inventory item, event, space) for removal, which immediately hides it and notifies the partner."*
Spec: `docs/user-stories.md:287`.

## Goal
An owner (MFA admin session) can `POST /api/partners/flags` targeting one listing by `{content_type,
content_id}`. The listing is immediately hidden from reader surfaces, a `partner_content_flags` row is
written (the queue's backing record), and the owning partner is notified. Un-flagging (`DELETE`)
restores the listing.

## Scope Check
- Controllers: one new `PartnerFlagController` (create + delete). **1 controller.** ✅
- New endpoints: `POST /api/partners/flags`, `DELETE /api/partners/flags/:id`. **2 endpoints.** ✅
- LOC: migration for `op.partner_content_flags` + a polymorphic-ish flag model + hide-filter on 3 reader
  surfaces + notify. Borderline ~300 — keep the notification path thin (reuse existing partner-notify
  mechanism if one exists; otherwise a single `partner.listing_flagged` event that a notifier subscriber
  handles, deferring the actual email channel to that subscriber). If the notifier does not exist,
  emit the event in-scope and spin the delivery channel into its own issue.
- Mixed concerns? Flag model + hide + notify are one concern (takedown of one listing). ✅

## Wiring
- [x] This issue includes router wiring and is user-facing (owner-facing) when complete.
- [ ] Implementation only.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-9.6.1 pt 3 — flag/takedown one listing | No flag model/table; no route; reader surfaces have no per-item hidden filter; no partner notification | ⬜ to verify at pickup | ❌ MISSING | **Build in-scope** (this issue). |

Verdict: ❌ missing — built by this issue.

## Technical Requirements
### 1. Flag model — `op.partner_content_flags`
- Columns: `id` (uuid), `partner_id` (fk), `content_type` (`inventory_item` | `third_space_event` |
  `third_space` — CHECK-constrained), `content_id` (uuid of the flagged row), `reason` (text, owner's
  note), `source` (`manual` for this issue; `automated` reserved for #246), `flagged_by_id`,
  `resolved_at`/`resolved_by_id` (null until un-flagged / dispositioned), timestamps.
- Add to proto (`proto/stacks/internal/v1/`, new `partner_content_flag.proto`) and run `mix proto.sync`
  — do NOT hand-write the Ecto schema (proto-generated convention, MEMORY). Register in
  `proto/persisted.exs` so the schema + `stg_partner_content_flags` dbt staging model generate.
- `reason` is free text authored by the **owner** (not a user) → not personal data of a data subject;
  confirm with the gdpr-review lens that it stays out of user export/erasure scope (it's owner/partner
  moderation metadata, not user PII).

### 2. Context: `Stacks.Partners` (or a new `Stacks.Partners.Moderation` submodule)
- `flag_listing(%{content_type, content_id, reason}, admin_id)` — validates the target exists and
  belongs to a partner, inserts the flag, emits `partner.listing_flagged`
  (`aggregate_type: content_type`, payload: partner_id + content_type + content_id + reason; **no
  reader PII**). Returns `{:ok, Flag}` / `{:error, :not_found | :already_flagged}`.
- `unflag_listing(flag_id, admin_id)` — sets `resolved_at`, emits `partner.listing_unflagged`, restores
  visibility.
- `flagged?/2` helper (`content_type`, `content_id`) used by the reader-surface filters.

### 3. Hide the single flagged item from reader surfaces
- Reader reads of inventory / events / third-spaces MUST exclude rows with an **unresolved** flag. Add a
  `LEFT JOIN op.partner_content_flags ... WHERE flag.id IS NULL OR flag.resolved_at IS NOT NULL` (or an
  `EXISTS` anti-join) to each of the three surfaces (same sites #243 touches for partner-level hiding —
  coordinate so the two filters compose: hidden if partner suspended **or** the item is flagged).
- Enumerate the exact query sites at pickup (US-9.8.1 Available-Locally inventory join;
  `list_partner_events`/event surfaces; third-space map). A missed surface is a takedown that doesn't
  take down.

### 4. Notify the partner
- On flag, notify the owning partner (their content was removed + reason). Prefer emitting
  `partner.listing_flagged` and letting a notification subscriber handle delivery (Oban), consistent
  with the event-driven architecture (CLAUDE.md §Event-Driven). If no partner-notification channel
  exists yet, emit the event in-scope and spin the delivery channel into a follow-up issue (note it).

### 5. Owner endpoints
- `POST /api/partners/flags` + `DELETE /api/partners/flags/:id` in the MFA-admin scope
  (`core_web/router.ex:306`). The flag rows are what #245's queue lists.

## Reviewer Context
- The three flaggable content types live in different tables/contexts (`InventoryItem`,
  `ThirdSpaceEvent`, `ThirdSpace`) — the flag is a lightweight polymorphic pointer
  (`content_type` + `content_id`), not a FK per type, to keep it one table. Validate the target exists
  in the context, not via DB FK.
- Reader-surface hiding must **compose** with #243's partner-status filter — design the two as
  independent `WHERE`/anti-join clauses on the same queries, not mutually exclusive branches.
- Owner-authored `reason` is moderation metadata, not user PII — but route through gdpr-review to
  confirm it never lands in a user's export/erasure path.
- Proto-generated schema: never hand-edit `apps/core/lib/stacks/gen/**`.

## Test Audit
_Baseline — backlog issue. Load-bearing: the per-item hide (composing with partner-level hide) and the
notify path._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Flag model + migration (+ proto.sync + persisted.exs) | yes | ❌ (→ ✅ migration + schema test; CHECK on content_type) |
| Context: flag/unflag transitions + guards | yes | ❌ (→ ✅ moderation_test: flag → hidden, unflag → visible, already_flagged) |
| Reader-surface hiding, per content_type | yes | ❌ (→ ✅ per-surface test: flagged item absent; composes with suspend filter) |
| Event flow (`partner.listing_flagged`/`_unflagged`, PII-free) | yes | ❌ (→ ✅ event emitted, payload PII-free) |
| Notify partner (Oban subscriber or event → follow-up) | yes | ❌ (→ ✅ subscriber invoked / event emitted; delivery tested or spun out) |
| dbt `stg_partner_content_flags` | yes | ❌ (→ ✅ staging model generates + schema test) |
| Owner endpoints (route + shape + MFA guard) | yes | ❌ (→ ✅ controller test: 201 flag, 204/200 unflag, 404, 403 non-admin) |
| 11/12 metrics/perf | partial | n/a — SLO gate; add a takedown counter if the §9.6 dashboard tracks it |

Punch: (1) flag model + migration + proto.sync; (2) flag/unflag context + events; (3) per-surface
hide filters composing with #243; (4) partner notification; (5) dbt staging; (6) owner endpoints.
Verdict: baseline — 6 punch items.

## Definition of Done
- [ ] `op.partner_content_flags` exists (proto-generated schema + staging model + persisted.exs entry).
- [ ] `POST /api/partners/flags` + `DELETE /api/partners/flags/:id` (MFA-admin) work end-to-end.
- [ ] Flagging hides exactly the one targeted listing from every enumerated reader surface; un-flagging
      restores it; the hide **composes** with #243's partner-status filter — tested per content_type.
- [ ] The owning partner is notified (subscriber invoked or `partner.listing_flagged` emitted with
      delivery tested or explicitly spun out).
- [ ] Events are PII-free.
- [ ] **Feature-Completeness Pre-Check is ✅** — flag → hidden + notify driven live locally.
- [ ] `just verify` passes; test audit GREEN; migration-safety + gdpr-review lenses applied.
- [ ] Meets the Completion Bar.

## Dependencies
- Depends on **#243** (status-enum reconciliation) for the composing reader-surface filters — build the
  hide clauses to layer with #243's partner-status filter.
- **Produces the `partner_content_flags` record that #245 (moderation queue) reads** — the manual
  `source: "manual"` flags; #246 adds `source: "automated"` flags to the same table.

## Agent Assignment
elixir-agent (flag model + context + reader-surface filters + endpoints), `mix proto.sync` regen.
Reviewers: elixir-reviewer + platform-reviewer; migration-safety + gdpr-review lenses.

## Progress Notes
[Updated by agents during execution.]
