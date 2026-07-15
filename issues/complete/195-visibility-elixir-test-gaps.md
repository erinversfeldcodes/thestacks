# Issue #195: Visibility — Elixir Test Gaps

**Epic:** #122 (E2E Test Suite — Privacy & Visibility) · integration branch `feat/122-e2e`

## Summary
Close the six enumerated Elixir-layer test gaps for the already-built visibility surface (stories US-10.1.1 / US-10.1.2 / US-10.2.1 / US-10.2.3 / US-10.3.1). Test-only — no production code, no new user stories.

## User Stories
None claimed. Hardens the Elixir layer for US-10.1.1, US-10.1.2, US-10.2.1, US-10.2.3, US-10.3.1 (all already built + server-side-tested per the #122 audit).

## Wiring
- [ ] This issue includes router/UI wiring and is user-facing when complete.
- [x] This issue is implementation only (test-only). Wired by n/a.

## Feature-Completeness Pre-Check
n/a — no new user stories claimed; builds/tests against the already-built surface (see #122 audit).

## Technical Requirements
Punch items #1–#6 from the #122 audit, verbatim in intent:
1. **(#1, SECURITY)** HTTP 422 when a shelf-visibility update exceeds the profile ceiling — `apps/core/test/stacks_web/bookshelf_controller_test.exs` (currently only unit-level `validate_visibility_ceiling/3`; no end-to-end HTTP assertion).
2. **(#2)** ViewAs content-endpoint integration: `GET …?view_as=unauthenticated` actually FILTERS the returned payload to the simulated audience (not just the plug halt) — `apps/core/test/stacks_web/bookshelf_controller_test.exs`.
3. **(#3)** `:rate_limit_social` 429 on the 21st block/unblock within a window — `apps/core/test/stacks_web/social_controller_test.exs`.
4. **(#4)** `list_blocked_users/2` pagination (>20 blocks → 20/page, `total` correct) + ordering `created_at desc` — `apps/core/test/stacks/social_test.exs`.
5. **(#5)** Blog `blog.post_created` / `blog.post_updated` event PAYLOAD asserts `{user_id, title, visibility}`, not just the event type — `apps/core/test/stacks/blog_test.exs`.
6. **(#6)** Recap → `tighten_posts_to_ceiling` path caps posts AND the `user.visibility_recap_completed` payload `posts_capped` count is asserted — `apps/core/test/stacks/workers/visibility_recap_job_test.exs`.

## Reviewer Context
- `Guardian.Plug.put_current_resource(conn, user)` (not `assign`) sets the Guardian resource in test conns.
- Coordinate the `:rate_limit_social` counter/assertion with metrics child #197.

## Definition of Done
- [ ] All 6 punch items (#1–#6) land as passing tests in the named suites.
- [ ] `just verify` passes.
- [ ] Tests written and passing (`just run mix test` for the touched suites).
- [ ] The #122 audit cells for punch #1–#6 go GREEN (0 ❌ / 0 ⚠️ for these cells).

## Dependencies
Epic #122. All targeted contexts/controllers already exist (see #122 audit "Feature status"). Soft-coordinates with #197 on the rate-limit counter.

## Agent Assignment
elixir-agent.

## Progress Notes
- 2026-07-14: Created as child of #122 epic (feat/122-e2e).
