# Retrospective: Wave D

**Issues**: #052a, #053a, #054a, #056, #064, #082, #052b, #052c, #053b, ADR 013
**Date**: 2026-03-21
**Phases completed**: 3 (Phase 1: #082/#052a/#064, Phase 2: #053a/#056, Phase 3: #054a + follow-ups #052b/#052c/#053b)
**Agents involved**: elixir-agent, database-agent, worktree agents (parallel implementation)

---

## Numbers

| Metric | Start of Wave D | End of Wave D |
|--------|-----------------|---------------|
| Tests | ~1020 | 1135 |
| Properties | 15 | 15 |
| Coverage | 77.8% | 82.0% |
| Commits | — | 37 |
| Files changed | — | 123 (8025 insertions, 173 deletions) |
| Issues completed | — | 10 (6 planned + 3 follow-up + 1 ADR) |
| ADRs written | 2 (011, 012) | 3 (+013) |

---

## What Worked Well

- **Parallel implementation agents for independent issues.** #052b, #052c, and #053b were implemented simultaneously by three agents. All three produced working code that compiled and passed tests on first merge. This cut implementation time roughly 3x for that batch.

- **Review-fix-review cycle caught real bugs.** The #054a listing CRUD went through 3 review rounds. Round 1 caught 7 P1s including a timestamp column mismatch (would crash at runtime), race conditions (TOCTOU on state transitions), and unbounded queries (DoS vector). Round 2 caught the `create_listing` placement check outside the transaction. All were genuine issues that would have caused production bugs.

- **ChangesetHelpers extraction.** Reviewers identified duplicated `format_errors/1` across 7 controllers. Extracting it was a clean P3 fix that reduced code duplication and made the codebase more maintainable.

- **Incremental dbt model review caught data corruption.** The database reviewer identified that `mart_community_read_count`'s incremental filter would overwrite full aggregates with partial counts — silent data corruption. The fix (re-aggregate full history for affected book_ids only) was non-obvious and would have been missed without review.

- **Scope rescoping worked smoothly.** Recognising mid-wave that full marketplace e-commerce was over-scoped for phase 1 led to ADR 013 and a much simpler classifieds model. The contact_info field was a 10-minute addition vs. weeks of payment/shipping integration.

- **Behaviour-based mocks are consistent.** Every new external dependency (DbtRunner, TogetherClient) follows the same pattern: behaviour module, real implementation, mock in test/support, `Application.get_env` to swap. This is now muscle memory.

---

## What Caused Friction

- **Worktree agent router overwrite (Phase 3, #054a).** The worktree agent implementing listing CRUD replaced the entire router.ex, losing blog, feed, metrics, and require_owner routes from Phase 2. Root cause: the worktree branched from a commit before Phase 2 routes were added, and the agent wrote the full file rather than merging. Required manual router reconstruction.

- **Ecto Multi.insert with static changeset short-circuits.** When moving the `create_listing` placement check inside the Multi, `Multi.insert(:listing, Listing.changeset(...))` with an invalid changeset (nil book_id) short-circuited before the `:placement` step ran. Had to change to `Multi.insert(:listing, fn _ -> ... end)` for deferred evaluation. This was a subtle Ecto behaviour that cost debugging time.

- **sqlfluff formatting churn on dbt models.** Every SQL file edit required multiple rounds of sqlfluff fixes (line length, select targets on new lines, indent rules). The auto-formatter (`sqlfluff fix`) often produced different output than what was written, requiring re-reads and re-edits.

- **Migration on main can't be amended.** The listings migration used `timestamps()` (creates `inserted_at`) but the schema expected `created_at`. Initially created a rename migration, then realised there's no production data and simplified by fixing the original migration directly. The back-and-forth cost time — should have checked earlier whether the migration was on main.

- **Context exhaustion on large sessions.** The Wave D session spanned multiple context compactions. Each compaction required re-reading files and re-establishing context. The orchestrator flow (plan → implement → gates → review → commit) generates a lot of back-and-forth that fills context quickly.

- **#052c agent incomplete output.** The dbt data quality agent returned with a truncated result message ("Now convert mart_platform_searchable.sql") suggesting it may have hit limits. However, inspection showed it had actually completed all work — the result summary was just cut off. Schema.yml entries were missing though, requiring manual addition.

---

## What Should Change in the Agent System

| Area | Change | Addresses friction point |
|------|--------|--------------------------|
| Worktree agents | When an agent modifies shared files (router.ex, registry.ex, application.ex, config.exs), it should read the CURRENT version from the main working tree, not the worktree's stale copy | Router overwrite |
| Implementation agents | Agents implementing dbt models should always include schema.yml entries in their output — add this to the dbt-agent prompt template | #052c missing schema.yml |
| Review prompts | Include "check if Multi.insert uses static or deferred changeset evaluation" in Elixir review checklist | Multi.insert short-circuit |
| Orchestrator | Before creating a fix migration, check `git branch --contains <commit>` to determine if the original migration can be amended | Migration amendment confusion |

---

## Suggested Issues

- [ ] **#086 — FallbackController pattern** — Replace per-controller error handling with a Phoenix FallbackController for consistent error responses across all endpoints
- [ ] **#087 — Marketplace sold status flow** — Add `PUT /api/listings/:id/sold` endpoint so sellers can manually mark listings as sold (classifieds model)
- [ ] **#088 — BookDetailCache integration** — Wire BookDetailCache into BookController.show for actual cache hits (currently the cache exists but isn't called from any controller)
- [ ] **#089 — Pre-filter books for LLM association** — Replace the 200-book limit with text search pre-filtering (match book titles/authors against post body before sending to LLM)

---

## Process Observations

The Wave C process improvements (#081) held up well:
- **Issue scoping rules** (max 3 controllers, 2 endpoints, 300 LOC) were followed — no issue exceeded scope
- **Scope lock after plan approval** worked — marketplace rescoping created ADR 013 and deferred issues rather than expanding #054a
- **Pre-review verification** (`just verify`) caught credo/format issues before reviewers saw them
- **"No flaky dismissal" rule** was not tested this wave (no flaky tests encountered)

New observation: **Parallel agent implementation is the biggest time saver.** When issues are truly independent (different files, different domains), launching 3 agents simultaneously and merging results is dramatically faster than sequential implementation. The key requirement is that shared files (registry, config, router) are handled in a separate commit after all agents finish.
