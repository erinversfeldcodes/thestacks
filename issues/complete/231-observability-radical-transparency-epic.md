# Issue #231 (EPIC): Observability & Radical Transparency

## Summary
Close the loop on operational metrics — the moderation/age-gate counters #228 emits are exposed at
`/internal/metrics` but **visualized nowhere** (`Core.PromEx.dashboards/0 == []`, no persistent
Prometheus/Grafana). This epic makes them observable on **self-explanatory dashboards** for
operators, AND — distinctively for The Stacks — turns that observability into a **user-facing
transparency feature**: teaching users what is observed about them (here and on platforms generally),
how operators actually diagnose outages, and why running a platform costs money — hence why "free"
platforms sell user data and this one does not.

## Why this is an epic (and merges into the #118 PR)
The work spans four concerns — dashboards-as-code, live metrics infra, a dashboard-authoring
standard, and a values-driven user-education surface (content design + implementation) — well beyond
a single issue's scope. Per the owner's decision (2026-07-15) this epic is developed on the **same
integration branch as #118 (`feat/118-e2e`)** and **all of it merges as part of the single #118 PR**:
no PR opens until BOTH #118 and #231 are complete and the integration branch is green under the
epic-level PE gate.

## Guiding principles
1. **Every panel teaches.** No bare number. Each dashboard panel carries a description: *what it
   measures, how it's measured, what it means, and what a change (spike/drop) indicates.* Encoded as
   a standard (#233) so all future dashboards inherit it.
2. **Transparency as product, not compliance.** The user-facing surface is honest and educational,
   grounded in the REAL telemetry we emit and the REAL GDPR audience/data model — not marketing.
3. **Right data source per surface.** Ops dashboards read **Prometheus** (`/internal/metrics`,
   cardinality-bounded, reset-on-restart). User-facing durable stats read **dbt marts / DB
   aggregates** — never the Prometheus counters (wrong tool for durable, user-visible numbers).
4. **Validatable.** "Observable in a dashboard" is proven, not assumed: dashboards are code, drift
   is caught by tests, and the live stack is smoke-tested.

## Child issues (DAG)

| # | Type | Scope | Depends on |
|---|------|-------|------------|
| **#230** | feat (ops) | **Moderation + age-gate dashboards-as-code + validation.** Grafana JSON (funnel + age-gate panels) via PromEx `dashboards/0`, each panel with an educational description; drift test (dashboard ↔ registered metric names) + live `/internal/metrics` exposure check. No live-Grafana dependency. | #228 (merged) |
| **#232** | infra | **Live metrics stack — Fly managed Prometheus + Grafana (`fly-metrics`)** [owner decision 2026-07-15: lowest cost + persists across deploys]. $0, bundled with Fly, time series stored independently of app machines. Add a `[metrics]` block to `fly.core.toml` pointing at the metrics endpoint (handle the `MetricsAuth` token wrinkle — e.g. an internal unauthenticated metrics port on the private network for Fly's scraper). Grafana at fly-metrics.net; smoke-test the panels resolve. NOT decided previously in docs (observability was a Phase-4-polish future item). | #230 |
| **#233** | standard | **Self-explanatory-dashboard standard** in `docs/agents/standards/` — every panel must teach (what/how/why/what-a-change-means). Retro-applied to #230. | — |
| **#234** | design ⭐ | **Transparency & platform-honesty design pass** (`docs/decisions/`). The content/UX for the user-facing education: (a) *what we observe about you* (honest inventory tied to real telemetry + the GDPR audience model); (b) *how we investigate outages* (demystify ops using the real moderation-funnel metrics as the worked example); (c) *why platforms cost money → why free platforms sell your data → why The Stacks doesn't.* Tone, surfaces, and the data source behind every claim. Design-first because it is content-heavy and values-laden. **[owner decision 2026-07-15: PUBLIC / unauthenticated for now** — a manifesto anyone can read, fitting the anti-surveillance ethos; the *general* "what we observe" (not personalised). Personalised "what we hold about **you**" defers to a future authenticated surface.] | #230 (uses its panels as the ops example) |
| **#241** | feat (data) | **Public transparency metrics API** — `GET /api/transparency/metrics`; whitelisted-PromQL proxy against Fly Prometheus (live, cached, token-guarded, degrade-on-absent) + public-safe dbt-mart aggregates. The whitelist/mart columns ARE the privacy boundary; anonymised only, linked-account excluded. ✅ built. | #232, #234 |
| **#235** | feat (page) | **Public `/metrics` transparency page** — Elm render of #241: live + durable panels each with a what/how/why teaching tooltip, a featured costs widget, one-hop GDPR data-rights links; reachable via navbar → About → `/metrics`. ✅ built. | #241 |
| **#242** | feat (page) | **Personal inference & de-anon education view** (authed, own-only, `/me/insights`) — a signed-in user sees ONLY their own derived inferences + a real k-anonymity fingerprint, to teach re-identification without PII. Strict own-only + ephemeral (never persisted), both tested. ✅ built. | #234, user data model |

## Wave 2 — metrics/dashboard retrofit across the completed platform (DEFERRED)
A cross-domain inventory (2026-07-15) of ~50 completed issues found metrics in four states: dashboarded
(moderation/age-gate, #230), **wired-but-undashboarded** (GDPR, rate-limit), **emitted-but-not-exported**
(visibility/social — #197 dropped the PromEx registration), and **never instrumented** (profiles/search,
auth-security, trusted-IP). These tickets close those gaps, each following the #230 pattern
(wire-if-missing → dashboard with teaching panels → drift test → **live-exposure test proving interaction
makes the metric appear**). **They are DEFERRED: authored now, but not started until the current
#118 + #231 epic ships its PR** (they are a follow-on wave, not part of the current PR).

| # | Domain | Wires | State found |
|---|--------|-------|-------------|
| **#236** | Visibility/social/ViewAs | register the 8 emitted-but-unexported families in PromEx + dashboard | emitted (#197), not exported |
| **#237** ⭐ | Auth & session **security** | refresh-reuse-detected, session-cap, MFA-verify + dashboard | security signals never instrumented |
| **#238** | GDPR data-rights | dashboard existing + export/deletion latency + audit-read | wired, undashboarded |
| **#239** | Profiles/discovery/search | search zero-result, profile-404, shelf-cap, handle claims + dashboard | never instrumented |
| **#240** | Platform/ops | dashboard existing + trusted-client-IP (#176) | wired, undashboarded |

Priority when Wave 2 starts: #237 (security) + #236 & #238 (both feed #234's transparency page) first,
then #239, #240. Already-delivered (NOT re-cut): #181 (refresh-revoke counter), #197 (emit+tests), #206
(auth §12 + rate-limit assertions).

## Approach options (for the ops-stack half)
- **A (chosen for #230):** dashboards-as-code, validated without a live Grafana — the dashboard JSON
  + a drift test asserting it references the exact registered metric names + a live `/internal/metrics`
  exposure check. Makes metrics "dashboard-ready + validated" independent of infra; PromEx
  auto-uploads when a Grafana exists. Recommended — decouples the testable win from the infra.
- **B:** dashboards only after standing up live Grafana (#232 first) — rejected as ordering: it blocks
  the validated, low-risk win on infra + secrets.
- **C:** skip dashboards, keep the SLO-gate point-in-time scrape — rejected: that gates a deploy, it
  does not let a human *observe/diagnose* over time, which is the whole point.

## Definition of Done (epic)
- [x] #230, #232, #233, #234, #241, #235, #242 each built + test-first, on `feat/118-e2e`.
- [x] The moderation/age-gate metrics render on a Grafana dashboard whose panels are self-explanatory
      (#233 standard satisfied), validated (drift test + live smoke test) — #230/#233.
- [x] The user-facing transparency surfaces educate on observation / outage-diagnosis / platform
      economics, grounded in real telemetry + the GDPR model, with their own tests — public `/metrics`
      (#241/#235) + authed own-only `/me/insights` (#242).
- [ ] Integration branch green under `just verify`; epic-level PE gate passes on the **combined
      #118 + #231** diff. ← NEXT
- [ ] Single PR (`feat/118-e2e` → `main`) covering #118 **and** #231 opens ONLY when all the above hold.

## Dependencies
Builds on #228's emitted+exposed metrics (merged). Shares the `feat/118-e2e` integration branch and
the #118 PR. GDPR: the user-facing "what we observe about you" content must stay truthful to the
actual telemetry/data model (route the design + implementation through the `gdpr-review` lens).

## Agent Assignment
Orchestrator-coordinated epic. Per child: platform-agent (#232 infra), elixir-agent + a dashboard
author (#230, #233), a design pass (#234), elm-agent + elixir-agent (#235+).
