# Retrospective: Wave E

**Issues**: #057a-e, #058a-c, #059a-b, #060a-c, #061a-b, #107, #086-088, #090, #092, #097-099, #101, #103-106, #084-085
**Date**: 2026-03-23
**Phases**: E.0 (backend fixes) + E.1-E.6 (Elm frontend) + pre-Wave E backend (#086-#106, #084-085)
**Agents involved**: elixir-agent, elm-agent, python-agent, worktree agents (parallel implementation)

---

## Numbers

| Metric | Start of Wave E | End of Wave E |
|--------|-----------------|---------------|
| Elixir tests | 1167 | 1175 |
| Elm tests | 287 | 292 |
| E2E tests | 142 | 142 |
| Properties | 15 | 15 |
| Elixir coverage | 82.0% | ~82% |
| elm-review errors | 44 | 0 |
| Commits | — | 66 |
| Files changed | — | 156 (12,108 insertions, 1,045 deletions) |
| Issues completed | — | ~30 (10 pre-wave backend + 15 Elm sub-issues + 5 quick fixes) |

---

## What Worked Well

- **Parallel Elm agent implementation across phases.** E.3 ran 4 issues simultaneously (ARIA, list view, enrichment, merge). All compiled on first merge. E.4 ran marketplace + blog + privacy in parallel. This pattern is now proven for Elm as well as Elixir.

- **Pre-Wave E backend prep.** Doing 10 backend issues (#086-#106) before starting Elm work meant every frontend issue had its API ready. No frontend issue was blocked by missing endpoints.

- **Issue splitting paid off massively.** The original 5 Elm issues (#057-#061) were each 300-500 LOC. Splitting into 15 sub-issues (max ~300 LOC each) meant each agent pass completed successfully without revision cycles. Compare with trying to do #057 (overlay + upload + settings + onboarding) as a single issue.

- **FallbackController (#086) before frontend.** Consistent error handling across all controllers meant the Elm API module could rely on predictable error shapes. No per-controller error format surprises.

- **Review cycles caught real bugs in every phase.** P1s caught: publish race condition (Cmd.batch for dependent operations), isOwner granting all users ownership, role not persisted through auth round-trip, mergeIsbn never populated, onboarding overlay blocking seeded users.

- **elm-review --fix reduced lint errors from 44 to 0.** The auto-fix tool cleaned up unused exports, imports, and variables across 20 files. Manual fixes for the remaining structural issues (unused type constructors, dead code) were small.

---

## What Caused Friction

- **E2E test updates were a significant tail.** Every UI change (overlay vs page, settings hub routes, upload verification step, user menu buttons vs links) broke E2E tests. Required 3 rounds of fixes: initial agent pass missed upload loading text change, settings selector ambiguity, and costs data dependency. The E2E suite is tightly coupled to CSS classes and page structure.

- **Onboarding overlay blocked the entire UI for seeded users.** `hasAnyPlacements` defaulted to `false`, showing the onboarding overlay before the API confirmed placements existed. Fix: default to `true` (assume placements exist) and only show onboarding after API confirms zero placements.

- **Settings hub created duplicate CSS class selectors.** Both the hub wrapper and sub-page content used `.page--settings`, causing strict mode violations in Playwright. Similarly `.page__title` appeared in both the hub sidebar and the sub-page. Required `.first()` / `.last()` scoping in tests.

- **Blog publish used Cmd.batch for dependent operations.** `Cmd.batch [save, publish]` fires both simultaneously but publish depends on save completing. Required restructuring to save first, then publish on SaveCompleted callback. This is the same class of bug as the Ecto Multi.insert static changeset issue from Wave D — sequential operations disguised as parallel.

- **Role not persisted through auth round-trip.** `encodeAuth` didn't include `role`, `decodeFlags` hardcoded `"user"`. This made admin pages completely unreachable until caught by reviewer. The admin nav, admin route guards, and admin page rendering all appeared correct but the data pipeline was broken.

- **Costs page depends on RefreshCostsJob.** After removing the boot `Task.start` (correctly, for fragility reasons), preview deployments have no cost data until the daily cron fires. E2E test had to be made resilient to empty data state.

- **elm-review config path confusion.** `elm-review` needs `--config elm-review` flag, and must be run from the `frontend/` directory. The auto-fix mode requires interactive confirmation or `--fix-all` with specific config paths. Cost 2 debugging rounds.

---

## Cross-Wave Patterns

### Keeps working
- **Parallel agent implementation** — now proven across Elixir, dbt SQL, Python, and Elm
- **Issue splitting** — Wave E's 15 sub-issues from 5 parents is the most aggressive split yet, and it worked
- **Review cycles** — caught 5+ P1s across 6 phases
- **Behaviour-based mocks** — no new friction in Wave E

### Keeps causing friction
- **E2E tests are the most expensive gate.** Wave E spent more time on E2E test updates (3 agent passes) than on any single Elm feature implementation. The tests are tightly coupled to CSS classes, page routes, and element types (button vs a).
- **Cmd.batch for sequential operations** — same bug pattern as Ecto Multi.insert. Both Elm and Elixir have "batch" abstractions that look parallel but are used for sequential workflows.
- **Auth data model gaps surface late.** The `User` type, `AuthResponse`, `encodeAuth`/`decodeFlags` form a data pipeline. Adding a field (`role`, `countryCode`, `city`) requires updating all 4 locations. Missing any one silently breaks features.

---

## What Should Change

| Area | Change | Addresses |
|------|--------|-----------|
| E2E tests | Use data-testid attributes instead of CSS classes for test selectors | E2E fragility |
| E2E tests | Add a pre-test fixture that ensures cost data exists | Costs data dependency |
| Elm auth | Create a single `AuthCodec` module for encode/decode/construct to prevent field drift | Auth pipeline gaps |
| Elm architecture | Lint rule or reviewer checklist: "Never use Cmd.batch for dependent operations" | Cmd.batch sequential bug |
| Onboarding | Default UI state to "hidden" for any overlay that depends on API data | Onboarding flash |

---

## Suggested Issues

- [ ] **#108 — data-testid migration** — Replace CSS class selectors in E2E tests with data-testid attributes on key interactive elements
- [ ] **#109 — AuthCodec module** — Single Elm module for User encode/decode/construct with all fields
- [ ] **#110 — E2E cost data fixture** — Pre-test script that calls RefreshCostsJob to ensure cost data exists on preview

---

## Process Observations

- **Wave E was the largest wave** — 66 commits, 156 files, 12K+ insertions across Elixir, Elm, Python, CSS, and E2E tests
- **The pre-Wave E backend prep pattern should become standard** — doing API work before frontend work eliminates an entire class of blocking dependencies
- **elm-review is now at 0 errors** for the first time — this should be maintained going forward
- **The E2E test suite is comprehensive** (142 tests) but brittle — the data-testid migration would make it resilient to CSS refactors
- **All 5 original Elm issues (#057-#061) are now complete** — the frontend has pages for every backend feature: bookshelves, upload, settings, marketplace, blog, privacy, metrics, admin, onboarding, accessibility
