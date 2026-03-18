# Issue #065: Load Testing with k6

## Summary
Write and run k6 load test scripts that validate the platform meets the performance targets defined in `docs/capacity-model.md`. Cover the critical read paths (shelf loading, book detail, search) and the critical write paths (upload, shelf moves, marketplace purchase).

## User Stories
Cross-cutting — validates performance for all Phase 1 stories under concurrent load.

## Goal
Quantitative evidence that the platform handles the target user counts from the capacity model. Identify bottlenecks before they hit real users. Establish a baseline for regression detection.

## Technical Requirements

**k6 scripts (`test/load/`):**

| Script | Scenario | Target |
|--------|----------|--------|
| `bookshelf_load.js` | 50 concurrent users each loading their shelf (200 books avg) | P95 < 100ms, P99 < 200ms |
| `book_detail_load.js` | 50 concurrent users opening book detail overlays | P95 < 150ms, P99 < 300ms |
| `search_load.js` | 20 concurrent users searching (local + platform-wide) | Local P95 < 100ms, Platform P95 < 500ms |
| `upload_flow.js` | 10 concurrent uploads (mocked vision — tests Phoenix + DB, not Modal) | P95 < 500ms for confirm step |
| `marketplace_browse.js` | 30 concurrent users browsing marketplace listings | P95 < 200ms |
| `mixed_workload.js` | Realistic mix: 60% reads (shelf/detail/search), 30% shelf moves, 10% uploads | All targets met simultaneously |

**Test data seeding:**
- k6 `setup()` function seeds test data via API or direct DB insert
- 50 test users, each with 200 books (10,000 books total), spread across 5 shelves
- 100 marketplace listings
- Enrichment data: price snapshots, review snapshots for at least 500 books

**Infrastructure:**
- Run against a deployed preview environment (not local dev — real Fly.io + Neon latency)
- `just test-load` recipe in justfile
- CI: optional job (triggered by label `load-test` on PR, not on every push)
- Results output: k6 JSON summary + threshold pass/fail

**Thresholds (from capacity model):**
```javascript
thresholds: {
  'http_req_duration{endpoint:shelf}': ['p95<100', 'p99<200'],
  'http_req_duration{endpoint:detail}': ['p95<150', 'p99<300'],
  'http_req_duration{endpoint:search_local}': ['p95<100'],
  'http_req_duration{endpoint:search_platform}': ['p95<500', 'p99<1000'],
  'http_req_duration{endpoint:upload_confirm}': ['p95<500'],
  http_req_failed: ['rate<0.01'],  // <1% error rate
}
```

**Bottleneck investigation:**
- If any threshold fails, document the bottleneck in results and file a sub-issue
- Common suspects: N+1 queries in book detail join, missing indexes on platform search, Ecto pool exhaustion under concurrent load

## Definition of Done
- [ ] 6 k6 scripts written covering all critical paths
- [ ] Test data seeding populates 50 users x 200 books
- [ ] All threshold targets pass against preview deployment
- [ ] `just test-load` recipe works
- [ ] Results JSON committed for baseline
- [ ] Any discovered bottlenecks documented with file:line references
- [ ] CI job exists (label-triggered, not on every push)

## Dependencies
Issue #063 (needs a deployed environment to test against). Can also run earlier against a preview deployment once Issues #046-048 are merged.

## Agent Assignment
platform-agent

## Progress Notes
