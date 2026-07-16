# ADR 020: Age-Gating Shipped Dark — Provider-Sourced Verification, No Self-Declaration

**Status:** Accepted
**Date:** 2026-07-16
**Deciders:** Platform owner
**Technical area:** Trust & safety, content moderation, feature flagging, auth/identity

---

## Context

Age-gating has two independent halves:

1. **Content marking** — is a given book "adults only"? (Now human-marked + owner-moderated — the
   automatic subject/BISAC classifier was removed as an unreliable oracle; see the moderation
   pipeline change on this branch.)
2. **User age assurance** — is a given viewer actually 18+?

We cannot yet integrate a real age-verification provider (Smile ID / Yoti / Sumsub-style KYC).
The interim mechanism today is **self-declaration** — a settings toggle "I confirm I am 18+". That is
not an acceptable assurance mechanism: it is trivially bypassed and legally weak. We do not want to
ship it, even dormant.

At the same time we do **not** want to delete the enforcement machinery (hide-from-listings, the 403
direct-URL gate, the visibility checks) and rebuild it later — that loses validated behaviour and
invites bit-rot. We want it built, tested, and **shipped dark** until a real provider exists.

## Decision

### 1. Ship dark behind a runtime flag
A single runtime flag `config :core, :age_gating_enabled` (env `AGE_GATING_ENABLED`), **default
`false` in production, `true` in test**, read through one helper `Stacks.FeatureFlags.age_gating_enabled?/0`.
When the flag is **off**:
- All three enforcement points are **no-ops** — `StacksWeb.Plugs.AgeGate.enforce/2`,
  `Stacks.Books.maybe_exclude_age_gated/2`, `Stacks.Visibility.check_age_gate/3`. Age-gated books
  behave exactly as public (shown in listings, no 403).
- All age-gating **UI is hidden** — the "adults only" upload checkbox, the upload age-gate notice,
  the book-detail age-gate block, the owner Book-Moderation route, and the onboarding age step.

**Not LaunchDarkly.** A SaaS flag service phones home per-eval and cuts directly against the
platform's self-hosted, cost-conscious, anti-surveillance ethos (the same ethos behind the ADR-019
transparency work). A runtime config flag matches the existing in-repo kill-switch pattern (the AI
kill-switch, `STACKS_E2E_TEST_HELPERS`, `ALLOW_SEEDS`) and is free. Revisit only if per-user or
gradual-percentage rollout is ever needed.

### 2. Verification is provider-sourced, never self-declared
- **Remove** the self-declared `PUT /api/settings/age_verification` endpoint, the
  `Page.Settings.AgeVerification` toggle UI + its route/nav link, and the informational
  "verify your age" onboarding step.
- **Keep** the schema (`users.age_verified`, `age_verified_at`, `age_verification_provider` — already
  present, previously unused). A new `Stacks.AgeVerification.record_verification(user, provider,
  verified_at)` becomes the **sole writer** of these fields — a stub now, wired to a real KYC provider
  callback in a future issue. Enforcement keeps reading `user.age_verified` unchanged.

### 3. Validated without a provider
Tests and E2E set the flag on and create an age-verified user through a `STACKS_E2E_TEST_HELPERS`-gated
helper (`PUT /api/test/age-verification` → `record_verification/3`). The full gate behaviour therefore
stays covered even though production has no verified users and no provider.

### 4. Content marking stays
The human "adults only" mark (raise-only for users, `Books.set_visibility_tier/3`) + the owner
override surface remain. They are inert while the flag is off and their UI is hidden in production, but
they are fully tested with the flag on and ready the moment a provider lands.

### 5. Telemetry repointed, not removed
`[:stacks, :age_verification]` now emits from `record_verification/3` (outcome `:success`/`:error`)
instead of the deleted self-declared endpoint, so the #230 Grafana panel and the 6-family
`dashboard_drift_test` stay green with only description copy updated. The `[:stacks, :age_gate,
:enforce]` counter only fires when the flag is on (enforcement runs).

## Consequences
- Production launches with age-gating **invisible and inert**. Flipping `AGE_GATING_ENABLED=true` —
  after a provider is integrated — activates the already-validated behaviour with **no code change**.
- A **future issue** integrates a real provider (Smile ID / Yoti / Sumsub): the provider callback calls
  `record_verification/3`, plus a user-facing verify flow and the onboarding step, redesigned for the
  provider (not self-declaration).
- The frontend gains its **first server-config channel** (`GET /api/config`) — reusable for future flags.

## Alternatives considered
- **Keep self-declaration, just flag it off** — rejected: keeps a mechanism we have decided is
  unacceptable, even dormant; the UI/endpoint would still exist to be re-enabled by mistake.
- **Delete age-gating entirely, rebuild later** — rejected: loses validated-shipped-dark and invites
  bit-rot; re-deriving the enforcement + visibility matrix later is costly.
- **LaunchDarkly / SaaS feature flags** — rejected: recurring cost + phone-home telemetry vs. the
  self-hosted ethos; overkill for a single global on/off. Right category, wrong fit at this scale.
