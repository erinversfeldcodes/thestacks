# ADR 018: Unified Audience Model for Visibility

**Status:** Accepted
**Date:** 2026-07-14
**Deciders:** Platform owner
**Technical area:** Security, access control, privacy, schema contract (protobuf)
**Supersedes vocabulary of:** the ad-hoc per-entity visibility enums
**Builds on:** ADR 006 (RLS + application-layer visibility), ADR 007 (protobuf as contract), ADR 009 (proto→schema codegen)

---

## Context

The word **"visibility"** currently names at least three unrelated concepts and is
implemented as **six disagreeing enums** plus **two contradictory rank maps**. This
grew organically as each feature (shelves, placements, blog, profiles, groups,
books) shipped its own vocabulary. The result is a subsystem that is hard to reason
about and has already produced live bugs.

### The six vocabularies in play today

| Entity | Field | Values | Source |
|--------|-------|--------|--------|
| Profile | `profile_visibility` | `owner / group / platform` (registration) — but settings-update only accepts `platform / owner` | `accounts.ex:46` vs `:116` |
| Bookshelf | `visibility` (+`visibility_group_id`) | `owner / group / platform` | `shelving.ex:27` |
| Placement | `visibility` | `owner / group / platform` | `shelving.ex:27` |
| Blog post | `visibility` (+`visibility_group_id`) | `owner / group / platform` | `blog.ex:460` |
| Book (catalog) | `visibility_tier` | `public / unlisted / private / age_gated` (only `public / age_gated` validated) | `books.ex:999`, `book.proto:40` |
| Group | `visibility` | `invite_only / platform` | `social.ex:24` |

Plus two rank maps that **disagree on where `group` sits and both invent a `public`
that is never a stored value**:

- `@visibility_rank = %{public 0, platform 1, owner 2}` — drives the parent→child ceiling; omits `group`. (`visibility.ex:18`)
- `@profile_visibility_rank = %{public 0, platform 1, group 2, owner 3}` — used only for tighten/loosen telemetry; inserts `group` mid-ladder and counts in the opposite direction. (`visibility.ex:338`)

### Concrete harm this has already caused

1. **A live E2E bug** (caught during the #122 epic): the shelf-visibility UI sends a
   shelf *name*, the backend fetched by *id*, producing a `CastError` → 400. The
   name/id confusion was masked by the vocabulary drift.
2. **`public` is a phantom tier** for shelves/placements — it exists in the ceiling
   rank map but is not a valid stored value, so `setShelfCeiling(shelf, "public")`
   returns **422**, while `setPlacement(book, "public")` is accepted. The E2E suite
   carries a workaround comment for exactly this (`privacy-placement.spec.ts`).
3. **`group` is reachable-but-unmanageable on profiles**: registration accepts it,
   settings-update and the Elm UI do not. A user can be stuck in a state they cannot
   change through the product.
4. **`public` vs `platform` are treated identically** by the resolver
   (`visibility.ex:158-159, 171-174`) yet modeled as distinct rungs — dead
   semantics that invite mistakes.

### The important insight

`Stacks.Visibility.resolve_visibility/2` **already** composes four *independent*
checks — profile ceiling → block → age gate → resource audience
(`visibility.ex:67-78`). The domain is therefore **already multi-dimensional**; only
the *types* pretend it is a single stringly-typed enum per entity. The fix is to make
the types reflect the dimensionality that the resolver already has.

---

## Decision

**Model visibility as ONE canonical `Audience` ladder plus a small set of orthogonal
overlays, defined in protobuf as the single source of truth, with each entity
declaring the subset of rungs and overlays it supports.** Three things that are
*called* visibility but are **not** reader-audience remain explicitly separate types.

### 1. The canonical `Audience` ladder (the one shared type)

A single ordinal ladder, ordered by **exposure** (ascending = more exposed). One rank
function replaces both existing rank maps.

```
proto enum Audience {
  AUDIENCE_UNSPECIFIED = 0;
  AUDIENCE_OWNER    = 1;  // exposure 0 — only the resource owner (self)
  AUDIENCE_GROUP    = 2;  // exposure 1 — owner + members of the referenced group
  AUDIENCE_PLATFORM = 3;  // exposure 2 — any authenticated platform user
  AUDIENCE_PUBLIC   = 4;  // exposure 3 — anyone incl. unauthenticated (RESERVED, see below)
}
```

- **Exposure rank:** `OWNER(0) < GROUP(1) < PLATFORM(2) < PUBLIC(3)`.
- **Ceiling rule (single definition):** a child's exposure must be **≤** its parent's
  exposure. `child_exposure <= parent_exposure`. This one comparison replaces
  `validate_visibility_ceiling/3` *and* subsumes the profile→shelf→placement chain
  *and* the tighten/loosen telemetry direction (`tighten` = exposure decreased).
- **`group` gets a real rung** (exposure 1), between platform and owner — reconciling
  the two maps that disagreed about it.
- **`AUDIENCE_PUBLIC` is reserved / disabled today.** Per US-10.4.1 the platform
  serves `noindex,nofollow` globally and unauthenticated users are always hidden, so
  the effective top rung is currently `PLATFORM`. `PUBLIC` is modeled now so the
  future per-user opt-in indexing story (impl-mapping Phase 6) has a home without a
  schema change. `platform` (authenticated everyone) and `public` (the open internet)
  are **distinct rungs**, never again conflated.

The `GROUP` rung references a group via the existing `visibility_group_id` companion
field (single-group today — see Open Questions on multi-group).

### 2. Orthogonal overlays (independent of the ladder — NOT rungs)

These already exist as independent checks in the resolver or as separate columns.
The ADR names them as first-class, opt-in dimensions:

| Overlay | Meaning | Effect | Today |
|---------|---------|--------|-------|
| **Grants** (specific-people) | An allowlist of specific users layered on top of `OWNER`/`GROUP` | Additive — *widens* audience | `visibility_grants` table; Issue #150 |
| **Discoverability** | `Listed` vs `Unlisted` — search-indexed / in discovery, or link-only | Orthogonal — reduces *findability*, not *reachability* | global `noindex` constant; `unlisted` value on books |
| **AgeGate** | Requires an age-verified viewer | Subtractive — hides from unverified | `visibility_tier = age_gated` on books/works |
| **Block** | Per-pair deny | Subtractive — mutual invisibility | `user_blocks`, resolver step 2 |

Key decompositions this forces:
- **`books.visibility_tier` is misnamed.** `age_gated` → the **AgeGate** overlay
  (boolean on the work). `unlisted` → **Discoverability = Unlisted**. `private` →
  `Audience = OWNER`. `public` → `Audience = PUBLIC` + `Listed`. The book stops being
  a fourth audience vocabulary; its "audience" is fixed (catalog is platform/public)
  and only the overlays vary.
- **Grants are additive, not ordinal** — the classic mistake is trying to slot
  "specific people" as a rung between owner and group. It is an allowlist *on top of*
  the chosen rung.

### 3. Resolver-computed overrides (never stored as an Audience value)

- **Marketplace exception:** an active `looking_for_home` listing
  (`listing_status = "active"`) is visible to all platform users **regardless** of
  profile ceiling, shelf, or placement audience (`visibility.ex:41-46`,
  `marketplace_exception?/1`; ADR-006). This is **state- and time-driven** (listings
  carry `expires_at` and a `draft→active→sold/expired/removed` lifecycle) and stays a
  documented override *inside the resolver*. It is **not** an Audience rung and must
  not be encoded as one — doing so would let a stale stored value outlive the listing
  state.

### 4. Explicitly OUT of the Audience type (kept as separate models)

Unifying "everything called visibility" would merge genuinely different concepts.
These stay separate **on purpose**:

- **Group shape** — `GroupType` (`close_friends / broadcast / subscription`) and
  `GroupJoin`/`GroupVisibility` (`invite_only / platform`). These describe a
  *container's* relationship directionality and *join* model. `Audience.GROUP` merely
  *references* such a group; the group's internal semantics are the group's own
  concern. **`subscription` is the reserved seam** for a future follower / subscriber
  (and eventually paid) audience — a subscriber audience is "members of my
  subscription group," so it needs **no new rung**, only that the group exists.
- **Data Classification Tiers 1–4** (GDPR: public / personal / sensitive /
  external-personal) — a data-*handling* / warehouse-exclusion / encryption
  classification. Unrelated to reader audience. Left entirely alone.
- **Per-item show/hide booleans** (`comments.visible`, `post_book_associations.visible`)
  and listing `status` — lifecycle flags, not audience.

### 5. Disambiguate the word "tier"

Three unrelated uses of "tier" currently collide. After this ADR:
- **Audience rung** — a position on the ladder (never "tier").
- **AgeGate** — replaces the `visibility_tier` age semantics.
- **Data-classification Tier (1–4)** — GDPR only.

### 6. Per-entity applicability matrix

Each entity opts into a subset. "Not all axes apply everywhere" is explicit
(e.g. `AgeGate` is meaningless on a profile):

| Entity | Audience rungs | Grants | Discoverability | AgeGate | Ceiling parent |
|--------|----------------|--------|-----------------|---------|----------------|
| **Profile** | Owner, Platform (Group reserved) | — | — | — | *(is the top ceiling)* |
| **Bookshelf** | Owner, Group, Platform | ✅ (#150) | future | — | Profile |
| **Placement** | Owner, Group, Platform | ✅ | future | inherits book | Bookshelf |
| **Blog post** | Owner, Group, Platform | ✅ (#150) | future | — | Profile |
| **Book (work)** | fixed: Platform/Public (not user-set) | — | Listed / Unlisted | ✅ | — |
| **Group** | *(not on the ladder — uses GroupType + GroupJoin)* | — | Group discoverability | — | — |

### 7. Protobuf as the source of truth

Per ADR-007 / ADR-009, the `.proto` files are canonical and generate Ecto schemas,
dbt staging models, Elm decoders, and Python/Rust types. The `Audience` enum and
overlay types are defined **once** in proto and generated everywhere:

- New `proto/stacks/common/v1/visibility.proto` defining `Audience`, `Discoverability`,
  and the `VisibilityGrant` shape (moved/aligned from `social.proto`).
- **Field numbers are forever** (CLAUDE.md, ADR-007). We **cannot rename**
  `VisibilityTier`, `ProfileVisibility`, `BlogVisibility`, or `GroupVisibility`. The
  migration introduces the new `Audience` enum additively, `reserved`s the retired
  enum values, and maps old→new at the persistence boundary during transition.

---

## Consequences

**Positive**
- **One enum, one rank function, one ceiling comparison, one validation list** —
  replacing six vocabularies and two contradictory rank maps.
- The **profile-validation inconsistency** (registration vs settings accept different
  sets) disappears: `group` is a first-class rung everywhere or offered nowhere, by
  the per-entity matrix — not by two hand-written `validate_inclusion` lists.
- The **`public` phantom** and the **`public`≡`platform` dead semantics** are gone.
- **Extensible without new rungs:** specific-people grants, subscriber/paid audiences
  (via subscription groups), and future public-internet indexing all attach as
  overlays or the reserved `PUBLIC` rung — no schema churn when they land.
- Proto-first means Elm/dbt/Python/Rust all move in lockstep via `proto.sync`.

**Negative / cost (this is a far-reaching change)**
- Touches **every layer**: proto → generated Ecto schemas (30 tables) → dbt staging
  (30 models) + intermediate/marts → Elm decoders (gitignored, regenerated) → Python
  (vision) / Rust (scraper) types → controllers → the resolver → **RLS policies**
  (ADR-006: both the application layer *and* the DB policies must change together, or
  the two enforcement layers diverge) → tests.
- **Data migration** required: rewrite existing rows to the new vocabulary
  (mapping below), across `op.users`, `op.bookshelves`, `op.bookshelf_placements`,
  `op.blog_posts`, `op.books`, `op.groups`.
- **Highest-consequence risk: inverting a ceiling comparison.** Standardizing the two
  rank maps into one ascending-exposure scale flips the direction of one of them. A
  sign error silently *leaks* private content. Mitigation is mandatory: the property
  test suite ADR-006 already requires for `resolve_visibility/2` must be extended to
  cover the full (audience × grant × age × block × ceiling) matrix and run green
  before RLS re-activation.

**Migration mapping (old → new)**

| Old value | Entity | New Audience | New overlay |
|-----------|--------|--------------|-------------|
| `owner` | profile/shelf/placement/blog | `AUDIENCE_OWNER` | — |
| `group` | shelf/placement/blog | `AUDIENCE_GROUP` (+ `visibility_group_id`) | — |
| `platform` | profile/shelf/placement/blog | `AUDIENCE_PLATFORM` | — |
| `public` (placement, phantom) | placement | `AUDIENCE_PLATFORM` | *(never truly public today)* |
| `visibility_tier = public` | book | `AUDIENCE_PUBLIC` (reserved→PLATFORM effective) | `Listed` |
| `visibility_tier = unlisted` | book | *(audience unchanged)* | `Unlisted` |
| `visibility_tier = private` | book | `AUDIENCE_OWNER` | — |
| `visibility_tier = age_gated` | book | *(audience unchanged)* | `AgeGate = true` |
| `invite_only` / `platform` | group | *(NOT audience — GroupJoin enum, unchanged)* | — |

**Testing requirement**
- Extend the `resolve_visibility/2` property suite (ADR-006) to the full overlay
  matrix; assert ceiling direction explicitly with a regression case for each old→new
  mapping row.
- `proto.sync --check` drift gate must stay green after regeneration.
- RLS role-switching integration tests must be updated in the *same* change as the
  application-layer rank function.

**Deferred / Open questions (resolved in the implementation issue, #209)**
1. **Multi-group visibility.** Today `visibility_group_id` is a single FK — a resource
   is scoped to exactly one group; US-11.1.5 only needs "this group or broader."
   Recommendation: **keep single-FK now**; design the `Audience.GROUP` type so
   cardinality can grow to a join table (`*_visibility_groups`) later without a
   vocabulary change.
2. **Enable `AUDIENCE_PUBLIC` now, or keep reserved?** Recommendation: **reserved** —
   effective ceiling stays `PLATFORM` until the per-user opt-in indexing story is
   scheduled.
3. **Discoverability as a stored per-resource field now, or keep global?**
   Recommendation: **model the type now, keep the global `noindex` behavior** as the
   default; wire per-user/per-visibility opt-in when Phase 6 anti-scraping lands.
4. **Phasing.** The refactor is too large for one atomic change (see #209 for the
   phase plan: proto+codegen → resolver+rank → controllers/Elm → dbt/warehouse → RLS
   + data migration, each behind the property suite).
