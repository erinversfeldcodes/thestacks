# Issue #193: Block a User — Frontend (Elm)

**Epic:** #122 (E2E Test Suite — Privacy & Visibility) · integration branch `feat/122-e2e`

## Summary
Build the block-user FRONTEND for US-10.1.2. The backend already exists and is tested; only the Elm client + UI are missing. De-scoped from #122 (its audit wrongly claimed this shipped).

Backend evidence (already built + tested):
- Routes: `apps/core/lib/core_web/router.ex:275-276` (block / unblock) + `:216` (blocked-users) → `apps/core/lib/stacks_web/controllers/social_controller.ex:11` (block) / `:30` (unblock) / `:40` (blocked_users).
- `frontend/src/Api.elm` currently has NO `blockUser` / `unblockUser` / `listBlockedUsers` functions (confirmed by grep).

## User Stories
US-10.1.2 (Block a User) — **frontend**.

## Wiring
- [x] This issue includes router/UI wiring and is user-facing when complete.
- [ ] This issue is implementation only. Wired by issue #___.

## Feature-Completeness Pre-Check
The named story's frontend is ❌ MISSING — no block/unblock/blocked-users Elm code or `Api` client exists (grep-confirmed). This child BUILDS it in-scope. Baseline verdicts below; fill file:line hops + live-drive when picked up.

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-10.1.2 — Block a User (frontend) | ⬜ to verify (build in-scope) | ⬜ to verify | ❌ → build here | Built in-scope by this child |

Verdict: ❌ missing → built in-scope by this issue. Becomes ✅ (built end-to-end + driven live on a preview) at DoD.

## Technical Requirements
1. **Api client fns** — `Api.blockUser`, `Api.unblockUser`, `Api.listBlockedUsers` in `frontend/src/Api.elm` (Bearer auth, `RemoteData`).
2. **Block action** — overflow/context menu on another user's profile/content → confirmation modal → on success the blocked user's content disappears.
3. **Blocked Users list** — in Settings → Privacy, with an Unblock button (content reappears on success).
4. **Elm state-machine tests** — happy path + sad paths (`already_blocked`, `not_found`) — punch #9.

**DESIGN note (Phase-1 research, not a full ADR):** determine which views must hide blocked content, and whether `Stacks.Visibility.resolve_visibility/2` (`apps/core/lib/stacks/visibility.ex`) already filters blocked users server-side so the FE only needs to re-fetch after a block/unblock (rather than filtering client-side). Do a short design pass first.

## Definition of Done
- [ ] `Api.blockUser` / `unblockUser` / `listBlockedUsers` implemented via `RemoteData`.
- [ ] Overflow-menu block action → confirmation modal → content disappears on success.
- [ ] Settings → Privacy Blocked Users list with working Unblock.
- [ ] Elm state-machine tests (happy + `already_blocked` + `not_found`) written and passing (punch #9).
- [ ] `just verify` passes.
- [ ] **Feature-Completeness Pre-Check is ✅ for US-10.1.2** — happy path built end-to-end and driven live on a preview.

## Dependencies
Epic #122. Backend (routes + `SocialController` + `Social` context) already exists. Blocks E2E child #199 (hard).

## Agent Assignment
elm-agent.

## Progress Notes
- 2026-07-14: Created as child of #122 epic (feat/122-e2e).
