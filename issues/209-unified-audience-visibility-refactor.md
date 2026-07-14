# Issue #209: Refactor visibility to the unified Audience model (proto-first)

## Summary
Replace the six ad-hoc per-entity visibility vocabularies and two contradictory rank
maps with a single canonical **`Audience`** ladder plus orthogonal overlays (Grants,
Discoverability, AgeGate, Block), defined **in protobuf as the source of truth** and
generated across Elixir, Elm, dbt, Python, and Rust. Implements ADR-018.

## Status (2026-07-14) — core DELIVERED; remainder reframed & de-risked

Two findings from the implementation pass **substantially reduced this issue's scope**
and disproved the "proto-first, far-reaching data migration" framing:

1. **Storage is Postgres ENUMs, not strings.** `visibility_level ENUM (owner, group,
   platform)` backs shelves/placements/profiles; `visibility_tier ENUM (public,
   age_gated)` backs books (blog/group use `text`). **The stored enum values already
   ARE the canonical Audience ladder** — so there is essentially nothing to migrate for
   the ladder, and no `ALTER TYPE` is needed while `public` stays reserved.
2. **`visibility_tier` has only two live values** (`public`, `age_gated`); the proto's
   `unlisted`/`private` were never added to the DB enum and have **zero rows** (proven by
   `visibility_tier_characterization_test.exs`). The "decompose into 3 axes" reduces to
   "the `age_gated` boolean already IS the AgeGate axis."

**DELIVERED (committed on `feat/122-e2e`):**
- ✅ The correctness core — collapsed the two contradictory rank maps into ONE
  `@audience_exposure` ladder (`owner<group<platform<public`); one ceiling check + one
  tighten/loosen classifier. **Fixed a latent bug**: `group` children were wrongly
  rejected under a platform parent. 178 tests + 6 properties green (parity verified
  case-by-case for owner/platform/public).
- ✅ Golden-master characterization test pinning `visibility_tier` resolution.
- ✅ One canonical source (`Visibility.audience_levels/0` + `profile_audience_levels/0`);
  Blog + Accounts point at it. **Resolved the profile inconsistency** — registration and
  settings now agree (`owner`/`platform`; `group` reserved for profiles, per the matrix).
- ✅ Fixed the stale `sources.yml` visibility docs; corrected the ADR migration table.

**GENUINELY FUTURE (new features, NOT a migration — do NOT treat as almost-done):**
these need new enum members + new resolver logic and have no existing data:
- `public` rung as a stored value (unauth/internet-indexable) + the Discoverability axis
  (`unlisted`) — gated on the US-10.4.1 opt-in-indexing story.
- `private`/owner-only books (`visibility_tier` currently coerced to public at resolve).
- Enforcing a `group` PROFILE as a real ceiling (SEC-3) — today a group profile behaves
  like platform; making it restrict to group members is a behaviour change to design.
- Proto contract-enum unification (one `Audience` proto enum) — low value since the
  enums are contract docs, not storage; deferred unless a wire consumer needs it.
- `shelving.ex` keeps a literal `@valid_visibilities` (its ceiling GUARD clause needs a
  compile-time literal); it equals `Visibility.audience_levels/0` by construction.

## User Stories
Cross-cutting — this is a refactor of the machinery behind the entire US-10.x epic
(US-10.1.1 profile, US-10.2.1 shelf, US-10.2.2 placement, US-10.2.3 blog visibility,
US-10.4.1 search privacy) plus US-1.1.4 age-gating and US-11.1.x groups. No user-facing
behaviour changes; the observable audience decisions must be **identical** before and
after (that is the primary regression bar).

## Goal
- One `Audience` enum + one exposure-rank function + one ceiling comparison, defined
  once in proto and generated everywhere.
- `books.visibility_tier` decomposed into `Audience` + `Discoverability` + `AgeGate`.
- The profile registration/settings validation inconsistency (accepts `group` vs not)
  gone — governed by the per-entity applicability matrix, not two hand-written lists.
- `public`/`platform` no longer conflated; `PUBLIC` modeled but reserved.
- `resolve_visibility/2` returns the **same** `:visible/:hidden` for every
  (viewer, resource, block, group, ceiling) combination as it does today — proven by
  an extended property suite that runs green before RLS re-activation.

## Scope Check
<!-- If any of these are true, split the issue before implementation. -->
- Touches more than 3 controllers? → **YES, by design.** This is a far-reaching,
  epic-level refactor explicitly authorized as appropriate for the privacy-visibility
  epic (#122). It is **phased** (below); each phase is independently reviewable and
  behind the property suite. Phases may be spun into child issues (the #121→#183 /
  #122→#194/#201 pattern) if a single PR proves too large — but they land on the
  epic's integration branch.
- Combines unrelated concerns? → **No** — every phase serves the single concern
  "unify the visibility vocabulary." RLS + data-migration are the *same* concern's
  storage layer (ADR-006 requires app + RLS to change together).

## Phase plan
Each phase is gated by the extended `resolve_visibility/2` property suite (see Testing).

1. **Proto + codegen.** New `proto/stacks/common/v1/visibility.proto` (`Audience`,
   `Discoverability`, aligned `VisibilityGrant`). `reserved` the retired values on
   `VisibilityTier`/`ProfileVisibility`/`BlogVisibility` (field numbers are forever).
   Run `mix proto.sync` + `scripts/gen-elm-proto.sh` + Python/Rust gens. Drift gate
   (`proto.sync --check`) green.
2. **Resolver + rank.** Collapse `@visibility_rank` and `@profile_visibility_rank`
   into one ascending-exposure rank; rewrite `validate_visibility_ceiling/3` as the
   single `child_exposure <= parent_exposure` check; keep the marketplace exception
   and age-gate/block overlays exactly as-is. **No behaviour change** — property suite
   proves parity.
3. **Contexts + controllers + Elm.** Point `Shelving`, `Accounts`, `Blog`, `Books`,
   `Social` and their controllers at the `Audience` type; regenerate Elm decoders;
   update `Types/Visibility.elm` to the four-rung ladder + overlays; delete the
   phantom-`public` workarounds. Per-entity matrix enforced (profile offers
   Owner/Platform; shelves/placements/blog offer Owner/Group/Platform).
4. **Warehouse.** Regenerate the 30 dbt staging models via `mix proto.sync`; update
   `int_visibility_resolution`, `mart_platform_searchable`, `mart_blog_activity`; fix
   the **stale `sources.yml` docs** (`profile_visibility (public, followers, private)`
   and blog `(public, followers, private, group)` — neither matches reality).
5. **RLS + data migration.** Rewrite existing rows to the new vocabulary (ADR-018
   mapping table); update the RLS policies (`20260319000008_enable_rls_policies.exs`
   lineage) **in the same change** as the rank function so the two enforcement layers
   never diverge; re-run the role-switching integration tests.

## Wiring
- [x] This issue includes router/context/UI wiring and is user-facing-neutral when
      complete (no behaviour change; same audience decisions).
- [ ] Implementation only.

## Feature-Completeness Pre-Check
<!-- This is a refactor of already-built stories, not a validation issue. The named
stories are all ✅ BUILT today (validated by the #122 epic); the pre-check bar here is
BEHAVIOUR PARITY, not new-feature completeness. -->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-10.1.1 profile visibility | ⬜ parity vs pre-refactor | ⬜ to verify | ⬜ | parity-only |
| US-10.2.1 shelf visibility | ⬜ parity | ⬜ to verify | ⬜ | parity-only |
| US-10.2.2 placement visibility | ⬜ parity | ⬜ to verify | ⬜ | parity-only |
| US-10.2.3 blog visibility | ⬜ parity | ⬜ to verify | ⬜ | parity-only |
| US-10.4.1 search privacy | ⬜ parity | ⬜ to verify | ⬜ | parity-only |
| US-1.1.4 age-gating | ⬜ parity (AgeGate overlay) | ⬜ to verify | ⬜ | parity-only |

Verdict: the bar is **identical audience decisions before/after**, proven by the
property suite (Phase 2/5) + the existing #122 browser E2E re-run green.

## Technical Requirements
- **ADR-018** is the design of record — follow its ladder, overlay decomposition,
  per-entity matrix, and old→new migration mapping exactly.
- **Proto-first (ADR-007/009):** the `Audience` enum is defined once in proto and
  generated; do NOT hand-edit `apps/core/lib/stacks/gen/` or the dbt staging models.
- **Field numbers are forever:** retired enum values are `reserved`, never reused.
- **ADR-006 defence-in-depth:** the application-layer rank change and the RLS policy
  change MUST land together (Phase 5). A divergence leaks or over-hides data.
- Keep the **marketplace exception** (`looking_for_home` + `listing_status=active`)
  and the **age-gate**/**block** overlays as resolver-level concerns — they are NOT
  Audience rungs.
- Open questions resolved here: single-group FK retained (type abstracts cardinality);
  `AUDIENCE_PUBLIC` reserved (effective ceiling = PLATFORM); Discoverability modeled,
  global `noindex` behavior kept as default.

## Reviewer Context
- `mix proto.sync` regenerates Ecto schemas, dbt staging, ProtoJSON, schema.yml;
  `scripts/gen-elm-proto.sh` regenerates the gitignored Elm decoders. After a proto
  change you MUST regenerate BOTH Elixir and Elm or elm-test breaks on stale `gen/elm`
  (this bit the #122 epic twice on #201/#203).
- Two rank maps exist today for a reason (ceiling vs telemetry-direction) and count in
  **opposite directions** — collapsing them flips one sign. This is the single
  highest-consequence line in the change; assert its direction with explicit tests.
- `platform` means "any *authenticated* user" — not the open internet. Unauthenticated
  are always hidden and `noindex` is global (US-10.4.1). Do not "fix" this by enabling
  `PUBLIC`.
- Toolchain: never bare `mix`/`elm-test`; run via `just run` (pinned flake toolchain)
  or you corrupt `_build`.

## Test Audit
<!-- COMPACT — this is a behaviour-preserving refactor; the app-layer US behaviour is
already covered by the #122 suite. The load-bearing new coverage is the parity property
suite + the codegen drift gate. -->

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Visibility resolver (property: audience × grant × age × block × ceiling parity) | yes | ❌ extend `visibility_test.exs` to assert old→new parity for every mapping row (→ ✅ when done) |
| Ceiling-direction regression (sign-flip guard) | yes | ❌ explicit per-rung ceiling tests (→ ✅) |
| Proto codegen drift (`proto.sync --check`) | yes | ❌ green after regen (→ ✅) |
| RLS role-switching integration | yes | ❌ updated with the rank change (→ ✅) |
| Browser E2E (privacy/placement) | yes | ❌ existing #122 specs re-run green unchanged (→ ✅) |
| dbt staging/marts (visibility columns) | yes | ❌ regenerated + `sources.yml` docs fixed (→ ✅) |
| 1–13 app/US layers (new behaviour) | no | n/a — no behaviour change; parity is the bar |

## Definition of Done
- [ ] `Audience` enum + overlays defined once in proto; Elixir/Elm/dbt/Python/Rust all
      generated from it; `proto.sync --check` green.
- [ ] One exposure-rank function + one ceiling comparison replace both rank maps and
      `validate_visibility_ceiling/3`; both old maps deleted.
- [ ] `books.visibility_tier` decomposed into Audience + Discoverability + AgeGate;
      profile validation inconsistency resolved via the per-entity matrix.
- [ ] Data migration rewrites all existing rows per the ADR-018 mapping; RLS policies
      updated in the same change (ADR-006 parity).
- [ ] **Parity proven:** extended `resolve_visibility/2` property suite green for every
      (viewer, resource, block, group, ceiling) combination + every old→new mapping row.
- [ ] **Feature-Completeness Pre-Check (above) ✅** — every named story's audience
      decisions identical before/after, observed on a live stack; #122 browser E2E
      re-run green.
- [ ] Every behaviour has a validation path (property/integration where sufficient;
      live-stack E2E for the browser flows).
- [ ] Tests written and passing (`just run mix test` / elm-test / dbt).
- [ ] Standards compliance verified (`just run just verify` passes).
- [ ] **Test audit GREEN** — 0 ❌, 0 ⚠️; regenerated as the final step.
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`).
- [ ] Stale `sources.yml` visibility docs corrected to the new vocabulary.

## Dependencies
- ADR-018 (this issue implements it).
- Epic #122 (lands on the epic's integration branch).
- ADR-006 (RLS + application visibility) — Phase 5 updates both layers together.
- ADR-007 / ADR-009 (proto-as-contract, proto→schema codegen).
- Coordinate with Issue #150 (visibility-grants-crud) — the Grants overlay is the
  home for "specific people"; #150 builds the CRUD, #209 gives it the type.

## Agent Assignment
Orchestrator (multi-phase, cross-stack). Specialists: elixir-agent (resolver/contexts/
migration/RLS), proto/schema work via `mix proto.sync`, elm-agent (Types/Visibility +
decoders), dbt for the warehouse phase. testing-coordinator owns the parity property
suite gate.

## Folded-in review findings (from the #122 code review, 2026-07-14)
Two P3s from the #122 reviewers are Audience-refactor territory and are de-scoped here
rather than patched piecemeal (fixing them properly means the unified model):
- **SEC-3 — `group` profile ceiling is unenforced.** `accounts.ex:46` accepts
  `["owner","group","platform"]` at registration, but `check_profile_ceiling/4`
  (`visibility.ex`) only treats `"owner"` as a hard ceiling — a `"group"` profile does
  not restrict `platform`/`public` shelves to group members. Resolve when the single
  `Audience` ladder gives `group` a real rung + one ceiling comparison.
- **FE-4 — ViewAsBar shows the raw `platform` label**, not the "Members" relabel
  (`Components/ViewAsBar.elm`). The relabel belongs in the shared `Audience` label
  function so every surface (placement dropdown, ViewAs banner) renders consistently.

## Progress Notes
- 2026-07-14: Filed from the ADR-018 design pass during the #122 epic. Scope validated
  against the full visibility inventory (9 consumers, 4 vocabularies, 2 rank maps) and
  the user-story/architecture audit for future-scope flexibility (GroupType,
  visibility_grants, subscription/follower seam, marketplace ceiling-punch,
  multi-group, public-vs-platform). Phased to keep each step behind the property suite.
- 2026-07-14: Folded in SEC-3 (unenforced `group` profile ceiling) and FE-4 (ViewAsBar
  raw `platform` label) from the #122 review — both are Audience-model work.
