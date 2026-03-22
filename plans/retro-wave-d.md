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

- **Umbrella runtime.exs vs app-level runtime.exs.** The app-level `apps/core/config/runtime.exs` contained all R2, scraper, SearXNG, and optional env var config — but production releases only use the umbrella root `config/runtime.exs`. This caused the Fly.io preview to use `Storage.Local` (file:// URLs) instead of R2, producing 422s from the vision sidecar. The same class of issue caused CI failures: `.env` vars (R2_ACCOUNT_ID, REQUIRE_EMAIL_CONFIRMATION) overrode test config, causing 4 test failures that only surfaced when CI loaded `.env`.

- **Worktree agent router overwrite (Phase 3, #054a).** The worktree agent implementing listing CRUD replaced the entire router.ex, losing blog, feed, metrics, and require_owner routes from Phase 2. Root cause: the worktree branched from a commit before Phase 2 routes were added, and the agent wrote the full file rather than merging. Required manual router reconstruction.

- **Ecto Multi.insert with static changeset short-circuits.** When moving the `create_listing` placement check inside the Multi, `Multi.insert(:listing, Listing.changeset(...))` with an invalid changeset (nil book_id) short-circuited before the `:placement` step ran. Had to change to `Multi.insert(:listing, fn _ -> ... end)` for deferred evaluation. This was a subtle Ecto behaviour that cost debugging time.

- **sqlfluff formatting churn on dbt models.** Every SQL file edit required multiple rounds of sqlfluff fixes (line length, select targets on new lines, indent rules). The auto-formatter (`sqlfluff fix`) often produced different output than what was written, requiring re-reads and re-edits.

- **Deploy script missing service credentials.** `deploy-stack.sh` didn't pass R2, Together AI, scraper, or Brave credentials to the Fly.io preview. Each missing credential caused a different feature to silently fall back to a no-op or local-only mode. Required iterative debugging against the live preview to discover.

- **Context exhaustion on large sessions.** The Wave D session spanned multiple context compactions. Each compaction required re-reading files and re-establishing context. The orchestrator flow (plan → implement → gates → review → commit) generates a lot of back-and-forth that fills context quickly.

- **#052c agent incomplete output.** The dbt data quality agent returned with a truncated result message. Schema.yml entries were missing, requiring manual addition.

---

## Cross-Wave Patterns (B → C → D)

### Keeps working
- **Parallel agent implementation** — validated in C and D, consistently 2-3x faster
- **Behaviour-based mock pattern** — mature by C, zero friction in D
- **Review cycles** — catch real bugs every wave (TOCTOU, data corruption, unbounded queries)
- **Issue scoping rules** — introduced in C (#081), held in D

### Keeps causing friction

1. **Config/runtime.exs is the #1 recurring problem.**
   - Wave B: reviewer false positives from global timestamp config override
   - Wave C: config merge complexity across 3 files, 8 client entries
   - Wave D: dual runtime.exs (only umbrella root used in releases), env vars overriding test config, R2/email flag bleeding into test env
   - **Root cause:** Config is scattered, environment-sensitive, and has no clear ownership boundary between dev/test/prod

2. **Shared files across parallel agents.**
   - Wave C: config collision, migration timestamp collision, manual file-copy merges
   - Wave D: router overwrite by worktree agent, registry/config as separate commit
   - **Mitigation that works:** Handle shared files (router, registry, config) in a dedicated commit after agents finish

3. **Proto-sync drift test fragility.**
   - Modifies a committed source file and relies on cleanup. Fixed three times (`async: false`, double-check restore). Still prints noise. Needs a fundamentally different approach.

4. **"Works locally, fails in CI" pattern.**
   - Wave D: coveralls exit code from .env contamination, ecto.drop with active connections, missing deploy secrets
   - **Root cause:** CI loads `.env` which overrides test config; local dev doesn't

---

## What Should Change in the Agent System

| Area | Change | Addresses |
|------|--------|-----------|
| Worktree agents | Read shared files (router, registry, config) from the main working tree, not the worktree's stale copy | Router overwrite (D) |
| Implementation agents | dbt agents must always include schema.yml entries | Missing schema.yml (D) |
| Review prompts | Check Multi.insert static vs deferred changeset evaluation | Multi.insert short-circuit (D) |
| Deploy scripts | All service credentials from .env must be forwarded to Fly.io previews | Missing deploy secrets (D) |
| Runtime config | Single runtime.exs at umbrella root, `if config_env() == :test` early return | Dual runtime.exs, env var test contamination (D) |

---

## Suggested Issues

- [ ] **#086 — FallbackController pattern** — Replace per-controller error handling with a Phoenix FallbackController for consistent error responses across all endpoints
- [ ] **#087 — Marketplace sold status flow** — Add `PUT /api/listings/:id/sold` endpoint so sellers can manually mark listings as sold (classifieds model)
- [ ] **#088 — BookDetailCache integration** — Wire BookDetailCache into BookController.show for actual cache hits (currently exists but isn't called)
- [ ] **#089 — Pre-filter books for LLM association** — Replace the 200-book limit with text search pre-filtering (match book titles/authors against post body before sending to LLM)
- [ ] **#090 — Proto-sync drift test isolation** — Rewrite the drift check test to use a temp directory copy instead of modifying the real generated file
- [ ] **#091 — Stacks.Config module** — Centralise all `Application.get_env` client lookups into a single module (Wave C suggestion, still unimplemented)
- [ ] **#092 — .env.example audit** — Fix variable name mismatches (S3_* vs R2_*), add missing vars (BRAVE_SEARCH_API_KEY, VISION_TOGETHER_API_KEY, SCRAPER_HMAC_SECRET, SEARXNG_SECRET_KEY, EMAIL_PROVIDER, RESEND_API_KEY)

---

## Process Observations

The Wave C process improvements (#081) held up well:
- **Issue scoping rules** (max 3 controllers, 2 endpoints, 300 LOC) were followed — no issue exceeded scope
- **Scope lock after plan approval** worked — marketplace rescoping created ADR 013 and deferred issues rather than expanding #054a
- **Pre-review verification** (`just verify`) caught credo/format issues before reviewers saw them
- **"No flaky dismissal" rule** was not tested this wave (no flaky tests encountered)

New observations:
- **Parallel agent implementation is the biggest time saver.** The key requirement is that shared files (registry, config, router) are handled in a separate commit after all agents finish.
- **Deploy debugging is expensive.** The R2/runtime.exs issue consumed more time than any feature implementation. Invest in deploy-time config validation (log which storage backend, which service URLs are active on boot).
- **The umbrella root config/runtime.exs is the single source of truth for releases.** App-level runtime.exs files are dev-only and should contain nothing that matters in production. This is now enforced by structure (app-level runtime.exs is a comment-only file).
