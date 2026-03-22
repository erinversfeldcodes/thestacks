# Issue #103: Source Approval Admin Endpoint

## Summary
Add admin endpoints for approving and rejecting discovered sources. Required by #059 (Elm enrichment display — US-2.5.1 source approval UI).

## User Stories
US-2.5.1 — Admin approves or rejects discovered sources from the approval queue.

## Goal
The admin can review discovered sources and approve or reject them via the API. The Elm frontend (#059) builds the UI on top of these endpoints.

## Scope Check
- 1 controller (or extend existing admin controller)
- 2-3 endpoints
- Context function additions
- ~100 LOC

## Technical Requirements

**Endpoints (behind :require_owner pipeline):**
- `GET /api/admin/sources` — list discovered sources, filterable by status (pending_review, approved, rejected)
- `PUT /api/admin/sources/:id/approve` — transition status to approved
- `PUT /api/admin/sources/:id/reject` — transition status to rejected

**Context (`Stacks.Discovery` or `Stacks.Enrichment`):**
- `list_sources/1` — accepts filter opts (status, type, page/per_page)
- `approve_source/1` — sets status to :approved, emits event
- `reject_source/1` — sets status to :rejected, emits event

**Events:**
- `source.approved` — payload: source_id, source_type, url
- `source.rejected` — payload: source_id, reason

## Definition of Done
- [ ] GET endpoint returns paginated sources with status filter
- [ ] Approve/reject endpoints transition status correctly
- [ ] Only owner role can access (require_owner pipeline)
- [ ] Events emitted
- [ ] Tests cover happy path, unauthorized, invalid status transitions
- [ ] `just verify` passes

## Dependencies
- DiscoveredSource schema exists (Wave C)
- RequireRole plug exists (Wave D)

## Priority
Required before #059 can be fully implemented.

## Agent Assignment
elixir-agent
