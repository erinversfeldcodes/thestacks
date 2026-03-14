# Issue #028: Login Page Aesthetic

## Summary
Design and implement the login and registration pages with The Stacks' dark-academic-meets-cottage-core aesthetic. The login experience should feel like approaching the entrance to a private library.

## User Stories
User stories for auth flows will be produced by #026. This issue implements the visual/aesthetic layer for those flows.

## Goal
A fully styled login and registration page that matches The Stacks' established visual language — warm parchment, serif typography, subtle animations, and the feeling of arriving at a curated, personal space. The pages should be functional (form inputs, validation feedback, error states) and beautiful.

## Technical Requirements
- Implement login page in Elm, consistent with existing SPA architecture
- Implement registration page in Elm
- Visual direction should draw from the aesthetic established in bookshelf stories (US-1.2.x): warm tones, parchment textures, serif typefaces, brass/wood accents
- Form inputs styled as library catalogue cards or similar physical-object metaphor
- Validation feedback: warm colour states (green for valid, amber for warnings, red for errors) matching existing patterns (US-1.1.5 ISBN input)
- Error states: clear, warm-toned messaging for incorrect credentials, account not found, etc.
- Transition animation when login succeeds — the "door opens" into the user's default bookshelf
- Mobile responsive
- No `unsafe-eval` in CSP (Elm constraint)
- Dependencies: #026 (auth user stories must exist first), auth backend (Guardian/JWT) from issue #001

## Definition of Done
- [ ] Login page implemented in Elm with full aesthetic treatment
- [ ] Registration page implemented in Elm with full aesthetic treatment
- [ ] Form validation with warm colour feedback
- [ ] Error states styled consistently
- [ ] Success transition animation
- [ ] Mobile responsive
- [ ] Tests written and passing
- [ ] Standards compliance verified

## Dependencies
- #026 (user story gap analysis — produces auth user stories)
- Issue #001 (Elixir MVP — Guardian auth backend)

## Agent Assignment
elm-agent

## Progress Notes
[Updated by agents during execution.]
