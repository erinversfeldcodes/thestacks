# Issue #245: Content moderation queue

## Summary
An owner-facing queue of flagged partner content — surfacing both **manual** flags (from #244) and
**automated** flags (from #246's text-policy checks) — with per-item **approve** (restore, dismiss the
flag) and **remove** (confirm takedown) actions. This is the "content moderation queue" the owner sees
in the Metrics Dashboard (US-9.6.1 "what they see").

**Domain:** partner-integration (§9). **DEFERRED — not part of the current #118+#231 PR.** Design/backlog.

## User Stories
US-9.6.1 (Platform Owner Reviews Partner Content) — "what they see": *"A content moderation queue showing
flagged items from automated checks (e.g., event descriptions containing blocked keywords)."*
Spec: `docs/user-stories.md:293`.

## Goal
`GET /api/partners/flags` returns the open moderation queue (unresolved `partner_content_flags`, newest
first, with enough joined context to render each card: partner name, content type, a snippet of the
flagged content, reason, source). The owner acts on an item with `PUT /api/partners/flags/:id/approve`
(restore + resolve) or `PUT /api/partners/flags/:id/remove` (confirm hidden + resolve). Every action is
audited and notifies the partner where appropriate.

## Scope Check
- Controllers: extend `PartnerFlagController` (#244) with `index` + `approve` + `remove`, **or** a
  dedicated `ModerationQueueController`. **1 controller.** ✅
- New endpoints: `GET /api/partners/flags`, `PUT /api/partners/flags/:id/approve`,
  `PUT /api/partners/flags/:id/remove`. **3 endpoints — exceeds the ≤2 convention.**
  → **Split option:** the `GET` (queue read + serializer) is separable from the two action endpoints.
  If the joined queue serializer is heavy, land the read in **#245a "moderation queue read"** and the
  approve/remove actions in **#245b**. Note the split here; decide at pickup. Kept as one issue on the
  assumption the actions are thin wrappers over #244's `unflag_listing` + a `resolve` disposition.
- LOC: mostly a joined read + serializer + two thin action fns. ~200-300. Borderline — see split above.
- Mixed concerns? Queue read + dispositions are one concern (moderation review). ✅

## Wiring
- [x] This issue includes router wiring and is user-facing (owner-facing) when complete.
- [ ] Implementation only.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-9.6.1 "what they see" — moderation queue + approve/remove | No queue read; no disposition actions; #244 writes flags but nothing lists/dispositions them | ⬜ to verify at pickup | ❌ MISSING | **Build in-scope** (this issue). |

Verdict: ❌ missing — built by this issue.

## Technical Requirements
### 1. Queue read
- `list_open_flags/1` (in the `Stacks.Partners.Moderation` submodule from #244) — queries
  `op.partner_content_flags WHERE resolved_at IS NULL`, ordered `created_at DESC`, joined to the partner
  (name/type) and to the flagged content for a **snippet** (e.g. the flagged event/space description, or
  the inventory ISBN/title). Support `?source=manual|automated` and `?partner_id=` filters and paging.
- Because `content_type` is polymorphic (#244), fetch the snippet per type (small dispatch), not a
  single join. Keep the snippet short (no full free-text dumps in a list payload).

### 2. Dispositions
- `approve_flag(flag_id, admin_id)` — the owner overrules the flag: restore the listing (reuse #244's
  `unflag_listing`) and mark `resolved_at`/`resolved_by_id` with disposition `approved`. Emits
  `partner.flag_approved`.
- `remove_flag(flag_id, admin_id)` — the owner confirms the takedown: the listing **stays hidden**, mark
  `resolved_at` with disposition `removed`. Emits `partner.flag_removed`; notify the partner the removal
  is final. (Consider a `disposition` column `open|approved|removed` on the flag, added via #244's proto
  or here via `mix proto.sync` — decide with #244 to avoid two migrations touching the same table.)
- Both idempotent-guarded (dispositioning a resolved flag → `{:error, :already_resolved}`).

### 3. Endpoint + serializer
- `GET /api/partners/flags` (MFA-admin scope, `core_web/router.ex:306`) → `{flags: [...], next_cursor}`
  where each entry carries `{id, partner: {id, name, type}, content_type, snippet, reason, source,
  created_at}`. `PUT .../approve` and `PUT .../remove` return the updated flag.
- The owner UI (US-9.6.1 index-card queue) consumes this — Elm rendering may be a separate wiring issue;
  note it if deferred.

### 4. Automated + manual unified
- The queue is source-agnostic: #244 writes `source: "manual"`, #246 writes `source: "automated"`;
  both land in the same table and the same queue. This issue must not special-case one source in the
  read/disposition logic (only expose the `source` filter).

## Reviewer Context
- Depends on the **`partner_content_flags` table + `unflag_listing` from #244** — this issue is the
  read + disposition layer over that record; don't duplicate the flag model.
- Snippets in the list payload must be short and must not leak reader PII (partner content is
  business-authored, but confirm no user data joins in) — gdpr-review lens on the serializer.
- Disposition `remove` keeps the listing hidden (it was hidden at flag time by #244); `approve` restores
  it — approve/remove are about the flag's fate, not a second hide/show toggle.
- MFA-admin scope only (owner action).

## Test Audit
_Baseline — backlog issue. Load-bearing: the polymorphic queue read/snippet and the two dispositions
composing with #244's visibility._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Queue read (filters, paging, per-type snippet) | yes | ❌ (→ ✅ moderation_test: open flags listed, resolved excluded, source/partner filters) |
| Dispositions (approve restores, remove keeps hidden, idempotency) | yes | ❌ (→ ✅ approve → visible again; remove → still hidden; already_resolved) |
| Event flow (`partner.flag_approved`/`_removed`, PII-free) | yes | ❌ (→ ✅ events emitted) |
| Notify partner on `remove` | yes | ❌ (→ ✅ subscriber/event as in #244) |
| Endpoint (route + serializer shape + MFA guard) | yes | ❌ (→ ✅ controller test: 200 queue, 200 disposition, 404, 403 non-admin) |
| Unified manual + automated source | yes | ❌ (→ ✅ both sources appear; source filter works) |
| Elm owner queue UI | yes | ❌ (→ ✅ Elm test) or n/a if UI deferred to a wiring issue |
| 11/12 metrics/perf | partial | n/a — SLO gate; queue depth/age gauge if the §9.6 dashboard tracks it |

Punch: (1) queue read + per-type snippet; (2) approve/remove dispositions + events; (3) partner notify
on remove; (4) endpoint + serializer; (5) unified-source tests; (6) owner UI.
Verdict: baseline — 6 punch items.

## Definition of Done
- [ ] `GET /api/partners/flags` returns the open queue with per-item render context (partner, snippet,
      reason, source), filterable by source/partner, paged.
- [ ] `PUT /api/partners/flags/:id/approve` restores the listing + resolves the flag;
      `PUT /api/partners/flags/:id/remove` keeps it hidden + resolves — both idempotent-guarded, both
      MFA-admin only.
- [ ] Manual (#244) and automated (#246) flags both appear in the same queue; no source special-casing.
- [ ] Dispositions emit PII-free events; `remove` notifies the partner.
- [ ] **Feature-Completeness Pre-Check is ✅** — queue listed + a flag approved and another removed,
      driven live locally.
- [ ] `just verify` passes; test audit GREEN; gdpr-review lens on the serializer.
- [ ] Meets the Completion Bar.

## Dependencies
- **Depends on #244** (the `partner_content_flags` table + `unflag_listing`). **Blocks #247** (partner
  name/address re-approval routes into this queue).
- Integrates with **#246** (automated text-policy flags land in this queue as `source: "automated"`).

## Agent Assignment
elixir-agent (queue read + dispositions + endpoints). Reviewers: elixir-reviewer + platform-reviewer;
gdpr-review lens on the serializer. Owner-UI (Elm) via elm-agent if wired in-scope.

## Progress Notes
[Updated by agents during execution.]
