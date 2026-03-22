# Issue #059b: Elm — Admin Pages (Source Approval + Scraper Config)

## Summary
Build admin pages for source approval queue and scraper configuration.

## User Stories
US-2.5.1 (source approval)

## Goal
Admin users can review and approve/reject discovered sources, and view scraper configuration.

## Technical Requirements
**`Page.Admin.SourceApproval`:**
- Queue of discovered sources from `GET /api/admin/sources?status=pending_review`
- Each: name, URL, type, confidence score
- Approve / Reject buttons calling PUT endpoints
- Status filter tabs (pending, approved, rejected)
- Paginated

**`Page.Admin.ScraperConfig`:**
- Read-only view of configured scrapers/stores
- Status per scraper (healthy/degraded/broken from source health API)
- Last success/failure timestamps

## Scope Check
- Create 2 page modules
- ~200 LOC

## Dependencies
#103 (source approval API — done)

## Definition of Done
- [ ] Source approval shows queue with approve/reject
- [ ] Status filters work
- [ ] Scraper config shows health status
- [ ] Owner-only access enforced (route guard)
- [ ] `elm-format --validate src/` passes

## Agent Assignment
elm-agent
