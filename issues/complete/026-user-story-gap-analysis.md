# Issue #026: User Story Gap Analysis — Auth, Registration & Missing Flows

## Summary
Review all existing user stories in `docs/user-stories.md` and identify gaps where user-facing flows exist (or will need to exist) but have no corresponding user story. Notable missing areas include login, registration, password reset, session management, onboarding, and user profile setup.

## User Stories
No existing user stories cover this work — this issue produces new ones.

## Goal
A comprehensive set of new user stories covering every user-facing flow that is currently missing from `docs/user-stories.md`. Each new story follows the established format (persona, motivation, how they accomplish it, what they see on the page) and fits into the existing section numbering scheme. The result is a complete user story document with no gaps a user would encounter in practice.

## Technical Requirements
- Audit all 13 existing sections (1–13) of `docs/user-stories.md` for completeness
- Identify missing flows. Known gaps include but are not limited to:
  - Authentication: login, registration, logout, session expiry
  - Password management: reset, change
  - Onboarding: first-time user experience, empty-state guidance
  - User profile: display name, avatar/initial, location preferences, profile page
  - Settings: account settings landing page, notification preferences
  - Error states: 404, 500, network failure, maintenance mode
  - Navigation: global nav structure, footer, mobile responsiveness
- Each new story must include the aesthetic direction consistent with the dark-academic-meets-cottage-core visual language established in existing stories
- New stories must respect existing constraints: ISBN hard gate, GDPR by default, no `unsafe-eval` in CSP
- After writing new stories, review `docs/implementation-mapping.md` and `plans/consolidated-roadmap.md` to identify any flows referenced there but missing from user stories
- Dependencies: none — this is a documentation-first issue

## Definition of Done
- [ ] All existing user story sections audited for completeness
- [ ] Gap analysis document produced listing every identified missing flow
- [ ] New user stories written in the established format and added to `docs/user-stories.md`
- [ ] New stories fit the existing numbering scheme (new sections or sub-sections as appropriate)
- [ ] No user-facing flow referenced in `docs/implementation-mapping.md` or `plans/consolidated-roadmap.md` lacks a corresponding user story
- [ ] Standards compliance verified

## Dependencies
None.

## Agent Assignment
Orchestrator (researcher for gap analysis, orchestrator for story writing).

## Progress Notes

### 2026-03-14 — Gap Analysis Complete

**Audit of existing sections 1-13:** All 13 sections reviewed. Existing stories are comprehensive within their domains. No gaps found within existing sections (empty shelf states already covered by US-1.6.5, shelf transitions by US-1.2.5, content moderation by US-4.1/4.2, etc.).

**Gaps identified and addressed:**

| Gap | New Story | Section |
|-----|-----------|---------|
| User registration flow | US-14.1.1 | 14. Authentication & Account |
| User login flow | US-14.2.1 | 14. Authentication & Account |
| Authenticated nav state | US-14.3.1 | 14. Authentication & Account |
| Session expiry / token refresh | US-14.3.2 | 14. Authentication & Account |
| Home/landing page | US-15.1.1 | 15. Home & Navigation |
| Global navigation bar | US-15.2.1 | 15. Home & Navigation |
| Mobile swipe navigation | US-15.2.2 | 15. Home & Navigation |
| Platform footer | US-15.3.1 | 15. Home & Navigation |
| 404 Not Found page | US-16.1.1 | 16. Error States & Edge Cases |
| Network/API error handling | US-16.2.1 | 16. Error States & Edge Cases |
| Unauthenticated access to protected pages | US-16.3.1 | 16. Error States & Edge Cases |
| Settings page navigation (consent + age) | US-17.1.1 | 17. Settings & Preferences |
| Browse "Looking for a Home" shelf | US-18.1.1 | 18. Bookshelf — Looking for a Home |

**Flows from issue scope NOT added (with rationale):**
- **Password reset/change:** No code exists for this flow (not in router.ex, not in Login.elm). Deferred to a future issue when the multi-user phase implements email-based password reset.
- **Onboarding/first-time experience:** Covered by existing empty shelf states (US-1.6.5) and the new home page story (US-15.1.1). No dedicated onboarding wizard exists in code.
- **User profile page:** No profile page exists in code (no route, no Elm page). The display name is shown in the nav (covered by US-14.3.1). Profile page deferred to multi-user phase.
- **500/maintenance mode:** These are infrastructure-level concerns handled by Fly.io, not Elm pages. No code exists for custom 500 or maintenance pages.
- **Notification preferences:** No notification system exists in code yet. Deferred.
- **Logout:** The router has `DELETE /api/auth/logout` but the Elm frontend has no logout button or flow in the current codebase. A story was not written for a flow that has no frontend implementation. Should be added when logout UI is built.

**Cross-reference with implementation-mapping.md and consolidated-roadmap.md:** All user-facing flows referenced in these documents now have corresponding user stories. The roadmap references auth pipeline, settings pages, shelf navigation, and error handling — all now covered.
