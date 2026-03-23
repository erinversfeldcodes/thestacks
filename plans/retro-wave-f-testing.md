# Retrospective: Wave F — Testing & Observability

**Issues**: #108, #128, #129, #130
**Date**: 2026-03-23
**Branch**: `test/108-data-testid-migration-and-others`
**Agents involved**: elm-agent, e2e-agent, elixir-agent, worktree agents (parallel implementation)

---

## Numbers

| Metric | Start (end of Wave E) | End of Wave F |
|--------|----------------------|---------------|
| Elixir tests | 1175 | 1185 (+10) |
| Elm tests | 292 | 292 |
| E2E tests | 142 | 168 (+26) |
| Properties | 15 | 15 |
| Deployed-only tests | 0 | 5 (excluded by default) |
| Commits | — | 10 |
| Files changed | — | 59 (2,196 insertions, 225 deletions) |
| Issues completed | — | 4 (#108, #128, #129, #130) |

---

## What Worked Well

- **Parallel agent execution across 4 issues.** #108 Elm, #128, and #129 ran simultaneously with zero conflicts. All three completed and passed verification before #130 launched.

- **data-testid migration (#108) was surgical.** 40 attributes added to 21 Elm files, 134 CSS selectors migrated to `getByTestId` across 18 E2E test files. No test logic changed — only selectors. Elm tests and E2E parsing verified clean after each step.

- **PromEx integration (#129) was zero-config.** `prom_ex` was already a dependency (v1.11.0). Added the module, configured plugins, and `/internal/metrics` endpoint worked on first deploy. 10 new telemetry tests verify all custom events fire correctly.

- **Mock-based Playwright tests (#130) validate Elm state machine against real DOM.** 26 tests covering all 8 upload user stories, using `page.route()` to intercept APIs. Catches Elm decoder/view regressions without needing the vision GPU.

- **Issue splitting + dependency ordering.** Doing #108 before #130 meant all Playwright tests used `data-testid` from the start. No selector rewrites needed later.

---

## What Caused Friction

- **`book-overlay` nested selector bug.** The E2E migration agent changed `page.locator('.book-detail__parchment')` to `overlay.getByTestId('book-overlay')` where `overlay` was `page.locator('[role="dialog"]')`. But `data-testid="book-overlay"` is ON the dialog element itself — `getByTestId` searches descendants, not self. Affected 8 tests across 4 files. Required a post-migration fix pass.

- **`page.getByRole({ name })` substring matching.** `{ name: "Library" }` matched both "Library" and "Antilibrary" buttons. Required `exact: true` on all shelf button assertions. Same issue with "Wish List" matching "Add to Wish List" confirm button.

- **Direct URL navigation renders `PageBookDetail`, not overlay.** The age-gate test navigated to `/books/:id` expecting `book-overlay` testid, but that only renders when opened as an overlay from a shelf. Direct URL renders `page--book-detail` (a full page, not a dialog). Required understanding the Elm routing model to fix.

- **Unauthenticated test in fresh browser context.** `browser.newContext()` creates a context without `baseURL`, so `page.goto("/upload")` didn't resolve correctly. Then `isVisible({ timeout: 5000 })` is not a valid Playwright API — it returns immediately with no timeout parameter. Required `waitUntil: "networkidle"` and `expect().toBeVisible({ timeout })` pattern instead.

- **Mock JSON shapes must exactly match Elm decoders.** The `fakeBook()` factory was missing `visibility_tier` (required by Elm's `bookDecoder` via `andThen` — no fallback) and edition objects were missing `id` and `is_primary` (required by `editionDecoder`). 17 mock-based tests failed silently on decoder errors until the fields were added.

- **Playwright config regex for project routing.** `/upload\.spec\.ts/` only matches `upload.spec.ts` literally, not `upload-pipeline.spec.ts`. The new file ran in the wrong project (chromium instead of upload-mock) until the regex was changed to `/upload.*\.spec\.ts/` for ignore and separate patterns for match.

- **Trivy timeout scanning `.venv`.** The vision sidecar's Python virtual environment (16MB+ bytecode files from `transformers`) caused Trivy to timeout. Fixed with `--skip-dirs apps/vision/.venv`.

---

## Cross-Wave Patterns

### Keeps working
- **Parallel agent implementation** — 4 agents ran simultaneously for independent issues
- **Issue splitting** — #108 before #130 eliminated selector rewrites
- **Review cycles** — caught the `book-overlay` nested selector bug before deploy

### New patterns established
- **`data-testid` is the standard for E2E selectors** — CSS classes remain for styling, testids for testing
- **Playwright projects split by execution mode** — `chromium` (parallel), `upload-mock` (parallel, mocked APIs), `upload` (serial, real GPU)
- **`@tag :deployed_only` for infrastructure-dependent tests** — excluded by default, run via `mix test --only deployed_only`
- **`/internal/metrics` for Prometheus scraping** — PromEx with Phoenix/Ecto/Oban plugins + custom telemetry events

### Keeps causing friction
- **Elm decoder strictness surfaces late.** Missing JSON fields fail silently (decoder returns `Err`, Elm shows nothing). No error in console, no crash — just an empty page. This is the same class of bug as the auth round-trip field drift from Wave E.
- **`page.getByRole` name matching is a footgun.** Substring matching by default means "Library" matches "Antilibrary". `exact: true` should be the default in our test patterns.
- **E2E tests against deployed stacks are slow feedback.** The deploy-test-fix cycle is 5+ minutes per iteration. Mock-based tests give instant feedback but don't catch server-side issues.

---

## What Should Change

| Area | Change | Addresses |
|------|--------|-----------|
| E2E test patterns | Always use `exact: true` with `getByRole({ name })` by default | "Library" matching "Antilibrary" |
| Elm decoder testing | Add a decoder smoke test that verifies mock JSON shapes match Elm decoders | Missing fields causing silent failures |
| E2E test helper | Create `openBookOverlay(page)` helper that returns `page.getByTestId('book-overlay')` | Prevent nested selector bugs |
| Playwright config | Document the 3-project split (chromium/upload-mock/upload) in a comment block | New developer onboarding |
| CI security scan | Keep `--skip-dirs` for vendored dependencies up to date | Trivy timeouts |

---

## Bugs Found and Fixed

| Bug | Found by | Fix |
|-----|----------|-----|
| `BookController.merge_format/2` missing `{:error, :isbn_not_found}` handler | Telemetry test (suite 11) | Added clause returning 422 |
| age-gate test navigating to overlay URL but page renders `PageBookDetail` | E2E deploy run | Changed selector to `.page--book-detail` |
| `fakeBook()` missing `visibility_tier` — Elm decoder silently fails | E2E deploy run | Added field to mock factory |
| Edition mock missing `id` and `is_primary` — decoder silently fails | E2E deploy run | Added fields to mock factory |
| Trivy scanning `.venv` bytecode causing timeout | Security scan | Added `--skip-dirs` to `security.sh` |

---

## Process Observations

- **This was the first dedicated testing wave.** Previous waves mixed features with tests. Separating test infrastructure (#108, #128) from test writing (#130) from observability (#129) worked well — each issue was focused and independently verifiable.
- **Mock-based E2E tests (26) provide fast regression coverage** for the upload pipeline without GPU costs. Real vision tests (5) validate the full pipeline end-to-end.
- **The deployed-only test infrastructure (#128) is minimal but functional.** The `test-deployed.sh` script and `@tag :deployed_only` exclusion pattern are ready for expansion as more deployed-only tests are written.
- **PromEx gives us Phoenix, Ecto, Oban, and BEAM metrics for free.** Custom telemetry events (vision, fuse, budget, costs) are now scrapeable. The `/internal/metrics` endpoint is production-ready behind Fly private networking.
