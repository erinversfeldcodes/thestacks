# Issue #104: Blog Association Confirm/Dismiss Endpoints

## Summary
Add endpoints for post owners to confirm or dismiss LLM-suggested book associations. Required by #060 (Elm blog UI — Components.BookAssociations).

## User Stories
US-12.1.2 — Owner reviews LLM book association suggestions: confirm keeps them visible to readers, dismiss hides them.

## Goal
After the LLM suggests book associations for a published post, the author can confirm (visible to readers) or dismiss (hidden) each suggestion via the API.

## Scope Check
- 2 new endpoints
- 2 context functions
- ~80 LOC

## Technical Requirements

**Endpoints (authenticated, ownership enforced):**
- `PUT /api/blog/posts/:post_id/associations/:id/confirm` — set `visible: true` on the PostBookAssociation
- `PUT /api/blog/posts/:post_id/associations/:id/dismiss` — set `visible: false` on the PostBookAssociation

**Context (`Stacks.Blog`):**
- `confirm_association/2` — accepts post + association_id, verifies ownership, sets visible: true
- `dismiss_association/2` — accepts post + association_id, verifies ownership, sets visible: false
- Emit `blog.association_confirmed` / `blog.association_dismissed` events

**Controller:**
- Add actions to BlogController or create a BlogAssociationController
- Return the updated association

## Definition of Done
- [ ] Confirm endpoint sets visible: true
- [ ] Dismiss endpoint sets visible: false
- [ ] Ownership enforced (only post author can confirm/dismiss)
- [ ] Events emitted
- [ ] Tests cover happy path, unauthorized, not found
- [ ] `just verify` passes

## Priority
Required before #060

## Agent Assignment
elixir-agent
