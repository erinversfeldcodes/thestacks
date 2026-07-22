# Issue #224: Group ("friends") profile visibility — design note

## Status: DESIGN NOTE — user story to be fleshed out before building

Captures the SEC-3 follow-up from the #209/#210 review. **Not a live security hole:**
`@profile_audience_levels` is `~w(owner platform)` today, so `group` is not a settable
profile visibility — there is no unenforced ceiling. This issue is about whether/how to
BUILD group-profiles as a feature.

## The concept (owner's words)
A `group` profile means **"my profile is private, but I have 'friends' who can see it."**
i.e. the profile is hidden from the platform at large, but visible to the members of a
group the owner nominates. It sits between `owner` (only me) and `platform` (any signed-in
user) on the Audience ladder — the "friends-only" rung.

## Decisions locked
- **Which group:** ONE chosen group, via a new `profile_visibility_group_id` FK on `op.users`
  (mirrors how shelves/placements already scope with `visibility_group_id`). A profile is
  restricted to a single named group, not the union of all the owner's groups. Chosen for
  precise, predictable semantics + a clear settings UI ("visible to: <group>").

## Open (needs the user story)
- **What the ceiling gates:** by the existing profile-ceiling model, a `group` profile would
  cap EVERYTHING — the hub + all shelves/placements become group-members-only; non-members
  get 404 (ghost-indistinguishable). Confirm this "whole-account" semantics is the intent
  (vs. e.g. only the hub page being gated).
- **Discoverability:** a group-profile user should be absent from people-search for
  non-members and 404 on `/u/:handle` for non-members (ghost-like), visible to members.
  Falls out of the ceiling; confirm.
- **UX:** the settings control (a group picker that only appears when "Friends only" is
  chosen); empty state if the user is in no groups; what happens if the nominated group is
  later deleted or the owner leaves it (fall back to `owner`?).
- **User story:** write US-10.x "Friends-only profile" with the visibility matrix
  (member vs non-member vs owner vs unauthenticated) as acceptance criteria.

## Implementation sketch (once the story is locked)
1. Migration: `add :profile_visibility_group_id, references(:groups)` on `op.users` (nullable).
2. `@profile_audience_levels` → `~w(owner group platform)`; require `profile_visibility_group_id`
   when `profile_visibility == "group"`.
3. `Visibility.check_profile_ceiling/4`: a `"group"` profile is `:hidden` unless the viewer is
   a member of `profile_visibility_group_id` (or the owner). One comparison on the existing
   Audience ladder — `group` already has a real rung (`@audience_exposure "group" => 1`).
4. Settings UI (group picker) + people-search exclusion of group-profiles for non-members.
5. Full visibility-matrix tests + a browser E2E row.

## Dependencies
The unified Audience ladder (#209 Phase 2, done) already gives `group` a real rung, so the
ceiling is one comparison. Group membership primitives exist (`Social`/`group_members`).

## Source
SEC-3, folded out of #209 during the #210 epic review.
