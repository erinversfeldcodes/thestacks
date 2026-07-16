# Issue #246: Automated partner text content policy / blocklist

## Summary
Add the **text-policy** validation layer to partner submissions: validate partner-authored free-text
fields (event descriptions, third-space descriptions) against a blocklist and a basic content policy —
no URLs to known-bad domains, no excessive capitalisation, no phone numbers in prose (those belong in
structured fields) — at the API boundary, returning structured JSON errors. The **structural** validation
(schema, dates-in-past, non-positive prices) already exists in `Stacks.Partners`; this issue adds only
the text layer, and routes borderline-but-not-rejected content into the #245 moderation queue as
`source: "automated"` flags.

**Domain:** partner-integration (§9). **DEFERRED — not part of the current #118+#231 PR.** Design/backlog.

## User Stories
US-9.6.2 (Automated Partner Content Validation) — point 2: *"Text fields (event descriptions, space
descriptions) are checked against a blocklist and basic content policy (no URLs to known-bad domains, no
excessive caps, no phone numbers in descriptions ...)."* Point 6: structured JSON errors.
Spec: `docs/user-stories.md:303,307`.

## Goal
When a partner submits an event (`POST /api/partner/events`) or a space description with free-text, a
`Stacks.Partners.ContentPolicy` validator runs at the API boundary. **Hard violations** (blocklisted
terms, known-bad-domain URLs) → **422 with structured JSON errors** and the content is not stored.
**Soft signals** (excessive caps, phone-number-in-prose) → either 422 or accept-and-auto-flag into the
#245 queue (design decision below). Structural validation is unchanged.

## Scope Check
- Controllers: none new — validation is invoked from the existing `PartnerEventController`
  (`stacks_web/controllers/partner_event_controller.ex`) and the space-description write path.
  **0 new controllers.** ✅
- New endpoints: none — this hardens existing write endpoints. **0 new endpoints.** ✅
- LOC: a `Stacks.Partners.ContentPolicy` module (blocklist + rules + structured-error shape) + wiring
  into 1-2 write paths + config for the blocklist/bad-domain lists. ~200-300. ✅
- Mixed concerns? One concern: partner text-content policy. ✅

## Wiring
- [x] User-facing (partner-facing structured errors) via existing endpoints — no new routes.
- [ ] Implementation only.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-9.6.2 pt 2 — text blocklist + content policy | `create_partner_event` (partners.ex:280) validates dates/structure only — **no text-content check**; space description write has no text policy; no blocklist config | ⬜ to verify at pickup | ❌ MISSING | **Build in-scope** (this issue). |

Verdict: ❌ missing — built by this issue. (Note: US-9.6.2 pts 1/3/4/5 — schema, ISBN, past-date, price
validation — are **already built** in `partners.ex`; this issue covers **only pt 2 + pt 6's text
errors**. Do not re-implement the structural checks.)

## Technical Requirements
### 1. `Stacks.Partners.ContentPolicy` module
- `validate_text(field_name, text) :: :ok | {:error, [violation]}` where each `violation` is a
  structured map `%{field:, code:, message:, ...}` (e.g. `code: "blocklisted_term"`,
  `code: "bad_domain_url"`, `code: "excessive_caps"`, `code: "phone_in_prose"`).
- **Blocklist:** a configurable list of blocked terms/keywords (module attribute + Application env
  override so an instance owner can extend it without a deploy — this is self-hosted). Case-insensitive,
  word-boundary matched (avoid the Scunthorpe problem — no naive substring).
- **Known-bad-domain URLs:** extract URLs from the text and reject any whose host matches a configurable
  bad-domain list. Reuse the excluded-domain concept if `businesses.status='excluded'`
  (`technical-architecture.md:1295`) already tracks bad domains — check before adding a parallel list.
- **Excessive caps:** ratio of uppercase letters over a threshold on strings above a min length.
- **Phone-in-prose:** detect phone-number patterns in description text (they belong in structured
  fields) — a conservative regex to avoid false positives on ISBNs/years.

### 2. Wire into the write paths
- `create_partner_event/2` (`partners.ex:280`) — run `ContentPolicy.validate_text("description", ...)`
  (and `"title"`) alongside the existing `validate_future`/`validate_ends_after_starts` in the `with`
  chain; on `{:error, violations}` return a new `{:error, {:content_policy, violations}}` tuple.
- The third-space description write path — same validator on the description field.
- `PartnerEventController.create` (and the space controller) map `{:error, {:content_policy, violations}}`
  → **422** with `%{errors: violations}` (structured JSON, US-9.6.2 pt 6). Follow the existing 422 error
  shape in that controller (`stacks_web/controllers/partner_event_controller.ex:27-51`).

### 3. Hard-reject vs auto-flag (design decision — resolve at pickup)
- **Hard violations** (blocklisted term, bad-domain URL): reject at the boundary — 422, not stored.
- **Soft signals** (excessive caps, phone-in-prose): choose one and document it —
  (a) also 422, or (b) accept the content but write an **automated flag** into `op.partner_content_flags`
  (`source: "automated"`, #244's table) so it surfaces in the #245 queue for owner review (the spec's
  "flagged items from automated checks" example, US-9.6.1). Recommended: hard-reject the unambiguous
  policy breaks, auto-flag the heuristic signals — matches the spec's "automated checks feed the queue"
  framing.

### 4. Structured errors (US-9.6.2 pt 6)
- All violations returned as machine-readable JSON `{errors: [{field, code, message}, ...]}` so a
  partner can programmatically fix and resubmit. Codes are stable strings.

## Reviewer Context
- **Do NOT re-implement structural validation** — schema (Protobuf), ISBN resolution
  (`resolve_edition_by_isbn`), past-date (`validate_future`), and non-positive price
  (`validate_number(:price_cents, greater_than: 0)`) already exist in `partners.ex`. This is the text
  layer only.
- Blocklist matching must avoid the Scunthorpe problem (word-boundary, not substring) — a naive filter
  is a known false-positive footgun; call it out in tests.
- The blocklist + bad-domain lists are **owner-configurable** (self-hosted instances differ) — config,
  not hard-coded constants; but ship a sane default.
- If it auto-flags (option b), it depends on #244's `partner_content_flags` table + writes
  `source: "automated"` for #245's queue.
- Existing 422 error shape lives in `partner_event_controller.ex` — match it.

## Test Audit
_Baseline — backlog issue. Load-bearing: each policy rule, the structured-error shape, and no
double-implementation of the existing structural checks._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| ContentPolicy rules (blocklist, bad-domain, caps, phone) | yes | ❌ (→ ✅ unit tests per rule incl. Scunthorpe/false-positive cases) |
| Boundary rejection (422 + structured errors) | yes | ❌ (→ ✅ controller test: violating event → 422 `{errors:[{field,code,message}]}`, not stored) |
| Happy path unaffected (clean text stored) | yes | ❌ (→ ✅ clean description passes, event created) |
| Auto-flag path (if option b) → #245 queue | yes/maybe | ❌ (→ ✅ soft signal writes `source:"automated"` flag) or n/a if option a |
| No regression on existing structural validation | yes | ❌ (→ ✅ existing partners_test date/price checks still green) |
| Config override (owner extends blocklist) | yes | ❌ (→ ✅ Application-env blocklist entry is enforced) |
| 11/12 metrics/perf | partial | n/a — SLO gate; rejection-rate counter if the §9.6 dashboard tracks it |

Punch: (1) ContentPolicy module + rules; (2) wire into event + space write paths; (3) 422 structured
errors; (4) auto-flag path (if option b); (5) config override; (6) regression tests for existing checks.
Verdict: baseline — 6 punch items.

## Definition of Done
- [ ] `Stacks.Partners.ContentPolicy` validates blocklist, known-bad-domain URLs, excessive caps, and
      phone-in-prose on partner text fields, word-boundary-safe.
- [ ] Hard violations return **422 with structured JSON** `{errors:[{field,code,message}]}` and are not
      stored; clean content passes unchanged.
- [ ] Soft signals handled per the documented decision (hard-reject or auto-flag into #245's queue).
- [ ] Blocklist + bad-domain lists are owner-configurable via Application env, with a sane default.
- [ ] Existing structural validation (schema/ISBN/date/price) is untouched and still green — no
      double-implementation.
- [ ] **Feature-Completeness Pre-Check is ✅** — a violating partner submission rejected with structured
      errors, driven live locally.
- [ ] `just verify` passes; test audit GREEN.
- [ ] Meets the Completion Bar.

## Dependencies
- Independent of #243 for the hard-reject path. **If the auto-flag path (option b) is chosen, depends on
  #244** (the `partner_content_flags` table) and **feeds #245** (automated flags in the queue).
- Layers on top of the existing structural validation in `apps/core/lib/stacks/partners.ex`.

## Agent Assignment
elixir-agent (ContentPolicy module + write-path wiring + structured errors). Reviewers: elixir-reviewer +
security-reviewer (SSRF/URL-parsing on the bad-domain check; ReDoS on the phone/caps regexes).

## Progress Notes
[Updated by agents during execution.]
