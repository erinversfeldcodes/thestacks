# Wave C Retrospective

**Branch:** feat/wave_c
**Date:** 2026-03-20
**Issues:** #050a, #050b, #051a, #051b, #051c, #068, #073, #083
**Also confirmed complete from Wave B:** #048, #074, #075, #078

## Summary

Wave C delivered the full enrichment infrastructure: price scraping, review summaries, author RSS intelligence, bookstore event discovery, source discovery with geographic sweep, source health monitoring, email confirmation gating, and RFC 2822 parsing fix. 10 issues completed across 3 phases.

| Issue | Title | Phase |
|-------|-------|-------|
| #050a | Price Enrichment Pipeline (Broadway + Fuse) | Phase 1 |
| #051a | Author Intelligence + RSS Polling | Phase 1 |
| #050b | Review Enrichment + LLM Summaries | Phase 2 |
| #051b | Bookstore Events + Third Space Discovery | Phase 2 |
| #051c | Source Discovery + Geographic Sweep + Opt-Out | Phase 2 |
| #068 | Source Health Monitoring | Phase 3 |
| #083 | Author RSS Fix (RFC 2822 + behaviour extraction) | Phase 3 |
| #073 | Email Confirmation Gate | Phase 3 |

---

## What Worked

### Issue splitting paid off
The original Wave C had 3 large issues (#050, #051, #068). We split #050 into 2 and #051 into 3, keeping each under 400 LOC. Every split issue was implemented in a single agent pass with zero revision cycles during implementation. Compare with Wave B's #080 which grew scope mid-flight and cost multiple review rounds.

### Parallel implementation with worktree isolation
All phases ran 2-3 agents in parallel via worktrees. Phase 1 (#050a + #051a), Phase 2 (#050b + #051b then #051c), Phase 3 (#068 + #083 + #073) — each completed in one agent pass. Merge conflicts in shared files (config, factory, registry) were predictable and mechanical.

### Process improvements from Issue #081 worked
- `just verify` caught dialyzer failures before review (Timex PLT, Author.t missing)
- Reviewer context in prompts prevented the timestamp naming false positive that cost a review round in Wave B
- `async: false` on tests that mutate Application.put_env eliminated the intermittent failure pattern
- Rate limiting on opt-out endpoint added proactively (per PE feedback pattern)
- dbt-checkpoint gates caught nothing new — schema.yml was already complete from Wave B fixes

### Behaviour + mock pattern is now mature
Six external client abstractions all follow the same pattern: behaviour → real impl → process-dict mock → Application.get_env wiring. ScraperClient, BraveClient, SearxngClient, TogetherClient, RssFetcher, ReviewFetcher. New developers can follow the pattern mechanically.

### Flakiness treated as a bug, not noise
Three sources of test instability were found and fixed:
1. Broadway PricePipeline sandbox conflict → conditional startup in test env
2. RefreshCostsJob startup Task → conditional skip in test env
3. AI ClientTest calling real GPU sidecar → switched to mock
4. Application.put_env race in async tests → async: false

All eliminated permanently, not papered over.

---

## What Caused Friction

### Worktree agents don't commit
Every worktree agent produced files but didn't commit to its worktree branch. This meant "merge worktree" was actually "manually copy files and resolve conflicts." The git merge workflow we planned didn't apply — we couldn't `git merge worktree-branch` because the branches had no commits. All merges were file copies.

### Ecto.Enum ↔ string mismatch
When we switched `DiscoveredSource` from `:string` to `Ecto.Enum`, 7 tests broke because assertions compared against string values (`"pending_review"`) instead of atoms (`:pending_review`). Ecto.Enum casts strings on write but returns atoms on read. This is a one-time learning but cost a debug cycle.

### `to_string()` needed for Monitoring calls
`Monitoring.record_success/2` expects string source_name, but `FetchReviewsJob` passes `source_data.source` which is an atom (`:goodreads` from Ecto.Enum). The FunctionClauseError was only caught at runtime, not at compile time. Guard clauses with `when is_binary(source_name)` prevented a clear error message.

### Three migration timestamp slots consumed
Phases 1-3 each needed unique index migrations. We used `20260320000001` through `20260320000004`. The collision between #050a (price snapshots, 000001) and #050b (review snapshots, also 000001 in its worktree) required manual renumbering. Migration timestamp coordination across parallel agents is a recurring friction point.

### Config file merge complexity
By Phase 3, `config.exs` had accumulated 8 client configs, `test.exs` had 8 mock wiring entries, and `runtime.exs` had multiple conditional blocks. Each agent added its entries independently, requiring manual merge of the same files every phase.

---

## What Should Change

### Worktree agents should commit their work
The orchestrator should instruct agents to `git add && git commit` in their worktrees before returning. This would enable real `git merge` instead of manual file copies. The merge conflicts would be resolved by git's merge machinery, not by manually reading diffs.

### Migration timestamps should be pre-assigned
Before launching parallel agents, assign each a specific migration timestamp range (e.g., agent A gets 20260320000001-000005, agent B gets 20260320000006-000010). This prevents collisions and manual renumbering.

### Accept atoms OR strings in Monitoring.record_*
Change `record_success/2` and `record_failure/3` to accept both atoms and strings via `to_string/1` internally, rather than requiring callers to cast. This prevents the Ecto.Enum → string mismatch from recurring.

### Consider a shared config module
Instead of 8 `Application.get_env` calls scattered across clients, consider a `Stacks.Config` module that centralizes all client lookups. This would make config changes a single-file edit instead of 3 config files.

---

## Metrics

| Metric | Value |
|--------|-------|
| Issues completed | 8 (+ 2 confirmed from Wave B) |
| Test count | 872 (up from 697 at Wave B end) |
| Test failures | 0 (3 flaky sources eliminated) |
| New modules | ~50 files |
| New dependencies | Broadway, ElixirFeedParser (Timex transitive) |
| Review rounds | Phase 1: 1 round (4 reviewers). Phase 2: 1 round (3 reviewers). Phase 3: 1 round (2 reviewers) |
| Blocking review findings | Phase 1: 1 (SCRAPER_HMAC in prod). Phase 2: 3 (event_date nullable, url unique index, Ecto.Enum). Phase 3: 0 |
| Credo issues | 0 across all phases |
| Dialyzer issues | 2 fixed (Author.t, Timex PLT) |
| dbt tests | 223/223 |
| dbt-checkpoint | 8/8 blocking |
