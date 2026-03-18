# Issue #067: Multi-User Stress Testing — Visibility, Concurrency, Data Isolation

## Summary
Targeted stress tests for the multi-user aspects of the platform: visibility correctness under concurrent access, data isolation between users, marketplace race conditions, and the block graph under load. These are the failure modes that only appear with multiple simultaneous users.

## User Stories
US-10.1.1 (profile visibility), US-10.1.2 (blocks), US-7.2 (marketplace purchase), US-1.5.3 (platform search)

## Goal
Prove that the visibility model, data isolation, and marketplace state machine are correct under concurrent multi-user access. No user ever sees another user's private data. No marketplace listing is double-sold. Block filtering is consistent even under concurrent block/unblock operations.

## Technical Requirements

**Visibility concurrency tests (`test/stress/visibility_stress_test.exs`):**
- Spawn 20 concurrent processes, each as a different user
- Each user: create a shelf, set visibility to various levels, create placements
- A "reader" process continuously queries other users' shelves via API
- Assert: reader NEVER sees content above the visibility level, even during concurrent visibility changes
- Assert: if User A blocks User B mid-test, B's subsequent requests immediately return 404 for A's content

**Data isolation tests (`test/stress/isolation_stress_test.exs`):**
- Spawn 10 users, each uploading books concurrently
- Assert: no user's shelf contains another user's books
- Assert: `bookshelf_placements` always have correct `bookshelf_id` FK chain to the owning user
- Assert: `GET /api/bookshelves/library` for User A never returns User B's placements, even under concurrent writes

**Marketplace race condition tests (`test/stress/marketplace_race_test.exs`):**
- Create a listing. Spawn 5 concurrent "buyers" each attempting to purchase simultaneously.
- Assert: exactly ONE buyer succeeds; the other 4 receive a clear error ("listing no longer available")
- Assert: `listing.sold` event emitted exactly once
- Assert: `transactions` table has exactly one row for this listing
- Assert: seller's placement is soft-deleted exactly once
- Implementation: use `Ecto.Multi` with `SELECT ... FOR UPDATE` on the listing row to prevent double-sell

**Block graph consistency tests (`test/stress/block_graph_test.exs`):**
- User A and User B are performing concurrent operations: A is posting to blog, B is browsing A's public shelves
- Mid-test: A blocks B
- Assert: from the moment of block, B sees 404 on ALL of A's content — no stale cache, no race window
- Assert: A also stops seeing B's content immediately

**Platform search under load (`test/stress/search_stress_test.exs`):**
- 50 users, each with 200 books (mix of public and private shelves)
- 10 concurrent search requests with `WholePlatform` scope
- Assert: no private shelf content appears in any search result
- Assert: blocked users' content never appears in searcher's results
- Assert: response time within capacity model targets (P95 < 500ms)

**Infrastructure:**
- Tests run against a real PostgreSQL instance (not Ecto sandbox — sandbox doesn't support true concurrency)
- Use `Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)` or a dedicated test database
- `just test-stress` recipe — separate from `just test` (these are slow, 30-60 seconds)
- CI: run as part of the `load-test` label-triggered job (Issue #065), not on every push

## Definition of Done
- [ ] Visibility stress test: 20 concurrent users, no visibility leak detected
- [ ] Data isolation test: 10 concurrent uploaders, zero cross-user contamination
- [ ] Marketplace race test: 5 concurrent buyers, exactly 1 succeeds, no double-sell
- [ ] Block graph test: block takes effect immediately, no stale window
- [ ] Platform search test: no private content in results, no blocked content in results
- [ ] All tests pass reliably (no flakiness — if flaky, investigate and fix the race condition)
- [ ] `just test-stress` recipe works
- [ ] Test infrastructure documented (why manual sandbox mode, how test DB is configured)

## Dependencies
Issue #047 (visibility must be implemented), Issue #054 (marketplace must be implemented), Issue #048 (settings + blocks must be wired). Best run late in the sequence when all multi-user features are complete.

## Agent Assignment
elixir-agent (Opus — concurrency correctness is hard)

## Progress Notes
