# ADR 019: Radical Transparency — Observability as a Public Product Surface

**Status:** Accepted
**Date:** 2026-07-16
**Deciders:** Platform owner
**Technical area:** Observability, transparency/privacy UX, metrics architecture
**Implements:** Epic #231. Design pass for #234 → informs #241 (data API) + #235 (page).

---

## Context
The Stacks emits a rich set of operational metrics (moderation funnel, age-gate, auth, GDPR,
rate-limit, costs, reliability) but visualizes them nowhere and exposes them to no one. The owner's
vision is not vanity stats — it is **radical transparency as a product feature**, fitting the
platform's anti-surveillance, GDPR-first, self-hostable ethos: teach users **what is observed about
them** (here and on platforms generally), **how operators actually diagnose outages**, and **why
running a platform costs money** — therefore why "free" platforms sell user data and this one does not.

## Decision

### 1. Surface & placement
- A **public, unauthenticated** page at **`/metrics`**, linked from the **About** page, which is
  linked from the **navbar** (keep the navbar uncluttered — a single About entry, with a
  metrics/**costs** highlight widget featured on About/the page). Costs is the flagship example.
- Voice: **plain and direct** with **placeholder prose** for now (owner writes the final copy);
  placeholder stance text on the ad-tech model, to be refined.

### 2. Data architecture — curated-public from BOTH sources
The boundary is **curated + anonymised vs. the full firehose**, NOT internal-vs-public. Prometheus
data *can* be public.
- **Ops Grafana** (Fly managed Prometheus, #232) = the *full* firehose — internal, operators.
- **Public `/metrics` page** = a **curated, whitelisted, anonymised subset** drawn from **both**:
  - **live rates / current values** — a *fixed PromQL whitelist* queried from **Fly's Prometheus**
    (cached, token-guarded), so users see the **same global, deploy-surviving signals operators see**
    (e.g. "isbn_not_found rate this hour"). Prometheus — not app-side ETS — because it already does
    multi-machine global aggregation + retention; ETS would be per-machine and reset on deploy
    (wrong, flickering numbers). See Alternatives.
  - **durable totals / ratios** — from **public-safe dbt marts** (`wh.mart_public_transparency`):
    total books, % age-gated, aggregate cost, exports/deletions, etc. Prometheus counters reset and
    can't total; marts are the durable source.
- Delivered by a **public transparency API** (#241): `GET /api/transparency/metrics` → `{live, durable}`.
  The **whitelist + mart columns ARE the privacy boundary** — nothing is public by default; adding a
  signal is an explicit, reviewed entry.

### 3. Anonymisation & the de-anonymisation boundary
- Everything public is an **aggregate** — never a per-user value; all low-cardinality atoms.
- **Linked-account / cross-integration signals** (future Audible-style integrations) are **excluded by
  construction** from the public page — they enable de-anonymisation by correlation.

### 3a. Personal inference & de-anonymisation view (authed, own-only) — #242
The authed counterpart to the public page: an **own-only** surface (under the profile/settings) that
shows a signed-in user **only their own** data-derived inferences, to educate on **(a) what can be
inferred about them** from their behaviour and **(b) how they could be de-anonymised even though the
platform keeps no PII.** This is the *point* of the feature — behavioural data is powerful and
re-identifying even without a name or email.

Load-bearing design rules (privacy-critical — a mistake here creates the exact harm the feature warns
against):
- **Strict own-only authz.** A user sees ONLY their own inferences; every query is hard-scoped to
  `current_user.id`. No cross-user path exists. This is the primary security invariant (tested).
- **Ephemeral — never persist derived inferences.** Compute on-the-fly from the user's *existing*
  records (shelves/placements, genres/BISAC subjects, reading/abandon timestamps, searches, age-gate
  interactions, consent) and render; **do not store** an inference profile. Persisting sensitive
  derived inferences would itself create a new special-category PII store (needing its own
  erasure/export/consent) — precisely what we must not do. Compute-and-display only.
- **Grounded + honestly labelled.** Real inferences ("your top genres/subjects") are shown as fact;
  risk inferences ("a data broker *could* infer interest in [sensitive topic] from this pattern") are
  clearly labelled *"what could be inferred"* — illustrations of risk, not classifications we assert or keep.
- **The de-anonymisation demonstration** (the powerful part): compute a real **uniqueness/rarity
  score** — e.g. "how many other readers share your top-N shelved books? *Zero.* Your combination is
  unique on this platform" — a concrete k-anonymity-style fingerprint from the user's own shelf vs the
  aggregate corpus. Explain that this fingerprint could be cross-referenced with public data (a
  Goodreads profile, a tweet) to re-identify them — **no PII required.**
- **Placement & consent-to-view.** Under the profile/settings (authed), distinct from public `/metrics`.
  Gate the sensitive-inference section behind an explicit "show me what could be inferred" action
  (informed choice), since some illustrations touch special-category topics.
- **Tone:** educational and empowering, not alarmist or manipulative — "here's what your data reveals,
  so you can choose". Plain+direct, per §1.

### 4. Themes (v1 — all backed by metrics we already emit)
| Theme | Backed by |
|-------|-----------|
| What we observe about you | the full telemetry inventory + GDPR data model (truthful, generated) |
| **Why platforms cost money** (flagship) | `stacks_budget_*`, `stacks_costs_recorded`, Modal per-call vision cost, `platform_costs` |
| How we investigate outages | moderation funnel, `events_handler_error`, `fuse_state`, latency |
| Content moderation & safety | classification / isbn_resolution / tiering, age-gate |
| Data rights in action | GDPR export/deletion/consent counters + one-hop to export/delete |
| Reliability | fuse state, handler errors, upload-terminal |
Start with all of them (thin), flesh out as we go. More themes emerge from Wave-2 metrics (#236–#240).

### 5. Ops dashboards are shown, not hidden
Per the owner: operator dashboards are *for* diagnosis but must **not be hidden from users**. The
public page re-presents the same curated signals **with teaching tooltips explaining why we measure
each and how we use it in investigations** — the public analogue of the #233 self-explanatory-dashboard
standard. Grounding: "what we observe" is a **truthful inventory** tied to the real telemetry + GDPR
model (can't drift), one hop from the data-rights surfaces (export/delete).

### 6. Governance rule (owner)
Every metric must **earn a dashboard panel** (ops) — and, where safe, feed the public page. *"If we're
not deriving insight, why are we measuring?"* Metrics with no panel are critically re-evaluated. This
is encoded in the #233 standard and the Wave-2 dashboard tickets.

## Consequences
- **#241** builds the public API (whitelisted PromQL proxy + public marts + anonymisation tests).
- **#235** builds the Elm `/metrics` page + About/navbar wiring + the costs widget + data-rights links.
- **#236–#240** (Wave 2) dashboards feed both the ops Grafana and the public mirror.
- The de-anonymisation boundary must be enforced at the **mart + whitelist** layer and GDPR-reviewed.
- Future: the owner-only de-anonymisation-education view (linked accounts) under the profile.

## Alternatives considered
- **App-side ETS rolling aggregates for live signals** — rejected: per-machine (diverges across Fly
  machines), resets every deploy, reinvents windowed aggregation, shows users different numbers than
  operators. Fly Prometheus already solves global aggregation + retention.
- **Marts-only (no live)** — rejected: can't answer "spiking this hour", which is the signal users
  most want to watch alongside operators.
- **Embed raw Grafana / proxy `/internal/metrics` publicly** — rejected: Grafana is authed and the
  firehose is ops-cardinality; the public surface must be a *curated, teaching* subset.
