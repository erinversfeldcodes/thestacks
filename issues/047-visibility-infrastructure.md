# Issue #047: Visibility Infrastructure — resolve_visibility/2 + Blocks + Property Tests

## Summary
Build the core visibility gate: `Stacks.Visibility.resolve_visibility/2`, the block graph (`Stacks.Social`), and `ViewAsPlug`. This is the single most security-critical piece of the system — every content read path must route through it. Property-based tests with StreamData are mandatory.

## User Stories
US-10.1.1 (profile visibility), US-10.1.2 (block user), US-10.2.1 (shelf visibility), US-10.2.2 (placement visibility), US-10.3.1 (view-as preview), US-10.4.1 (search engine privacy)

## Goal
A single authoritative function gates all content access. No controller returns user-generated content without passing through `resolve_visibility/2`. Blocked users see 404, not 403. Active marketplace listings punch through the profile ceiling. Property-based tests prove invariants hold across 1000+ randomly generated scenarios.

## Technical Requirements

**`Stacks.Visibility` context:**
- `resolve_visibility/2` — `resource :: struct(), viewer :: viewer()` → `:visible | :hidden`
- Viewer types: `:unauthenticated`, `{:platform_user, user_id}`, `{:group_member, group_id}`, `{:specific_user, user_id}`
- 4-clause evaluation in order: (1) profile ceiling, (2) block check, (3) age gate, (4) resource visibility
- Returns `:hidden` on all ambiguous or error cases
- **Marketplace exception**: if resource is a `bookshelf_placement` with `listing_status = 'active'` on a `looking_for_home` shelf, skip profile ceiling check — always visible to platform users. User can still restrict individual listings.
- `can_view?/2`, `viewable_shelves/2`, `viewable_placements/2` — convenience functions
- `validate_visibility_ceiling/3` — enforced on write: child visibility ≤ parent visibility

**`Stacks.Social` context:**
- `block_user/2`, `unblock_user/2`, `is_blocked?/2`, `blocked_by?/2`
- Block is bidirectional in effect: if A blocks B, both A→B and B→A content is hidden
- Block returns 404 (not 403) — no information leakage about resource existence

**`StacksWeb.Plugs.ViewAsPlug`:**
- Query param `?view_as=<perspective>` — sets viewer context on `conn.assigns[:view_as_context]`
- Perspectives: `unauthenticated`, `platform`, `user:<user_id>`, `group:<group_id>`
- Only the resource owner can use ViewAs on their own content — 403 for non-owners

**Anti-scraping:**
- All user-generated pages include `<meta name="robots" content="noindex, nofollow">`
- `robots.txt` disallows crawlers from `/u/`, `/shelf/`, `/post/`, `/listing/`
- Unauthenticated API requests to user-data endpoints return redirect to login, not data

**Property-based tests (`StreamData`):**
Generate random `(resource, viewer)` pairs and assert invariants:
- A blocked viewer NEVER sees `:visible`
- A viewer NEVER sees content above the profile ceiling (except active marketplace listings)
- An `:unauthenticated` viewer NEVER sees non-public content
- An age-gated resource is ALWAYS hidden from unverified viewers
- Active marketplace listings are ALWAYS visible to platform users regardless of profile visibility
- 1000+ generated test cases minimum

## Definition of Done
- [ ] `resolve_visibility/2` implemented with all 4 clauses
- [ ] Marketplace ceiling exception works correctly
- [ ] `block_user/2` and `unblock_user/2` work; blocked users see 404
- [ ] `ViewAsPlug` correctly impersonates viewer context; 403 for non-owners
- [ ] Property-based tests pass with 1000+ generated cases
- [ ] Anti-scraping meta tags and robots.txt in place
- [ ] `social.user_blocked` and `social.user_unblocked` events emitted
- [ ] `mix credo --strict` and `mix sobelow` pass
- [ ] `mix test` passes — no regressions

## Dependencies
Issues #042, #043 (user_blocks, groups, visibility_grants tables must exist)

## Agent Assignment
elixir-agent (Opus — SECURITY CRITICAL)

## Progress Notes
