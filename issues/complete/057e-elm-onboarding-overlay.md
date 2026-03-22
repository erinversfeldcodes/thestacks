# Issue #057e: Elm — Onboarding Overlay

## Summary
Build a 3-step onboarding overlay for first-time users after registration.

## User Stories
US-14.1.1 (first-time user experience)

## Goal
After first registration, a cinematic onboarding overlay guides the user through uploading their first book.

## Technical Requirements
- 3-step overlay: Welcome → Upload → Shelve
- Appears after first registration (check flag from API or local state)
- "Skip" link always visible
- Cinematic: slow zoom into empty shelf filling with first book
- Step 1: Welcome message with platform aesthetic
- Step 2: Upload prompt (reuse upload component)
- Step 3: Shelf placement confirmation
- Mark onboarding complete after finish or skip

## Scope Check
- Create `Components.OnboardingOverlay`
- ~200 LOC

## Dependencies
#057a (overlay pattern), #057b (upload flow)

## Definition of Done
- [ ] Overlay appears on first registration
- [ ] 3 steps with navigation
- [ ] Skip always available
- [ ] Animation on shelf filling
- [ ] Onboarding marked complete
- [ ] `elm-format --validate src/` passes

## Agent Assignment
elm-agent
