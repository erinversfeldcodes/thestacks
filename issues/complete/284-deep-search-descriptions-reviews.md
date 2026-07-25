# Issue #284: Deep Search Across Descriptions and Reviews

## Summary
Implement full-text "deep search" across book descriptions, review summaries, and subjects — the US-1.5.2 behaviour de-scoped from Issue #115 (which validated the shipped title-only search). Includes the `scope=deep` API parameter, `description_tsv` column + GIN index, `ts_headline` snippet generation, and the Elm "Deep search" toggle with "via deep search" result labels.

## User Stories
- US-1.5.2 — Full-Text Search Across Reviews and Descriptions (de-scoped from #115 at epic kickoff 2026-07-23; nothing of it is implemented today — backend searches `title_tsv` only)

## Goal
A user toggles "Deep search" on `/search` and finds books whose descriptions/reviews (not titles) match the query, with highlighted snippets showing why each result matched.

## Scope Check
- Does this issue touch more than 3 controllers? No (SearchController only).
- Does this issue add more than 2 new endpoints? No (extends `GET /api/search` with a `scope` param).
- Does this issue exceed ~300 lines of production code? Borderline — migration + query + snippets + Elm toggle; split the Elm slice if it grows.
- Does this issue combine unrelated concerns? No.

## Wiring
Router wiring: includes wiring (extends the existing `/api/search` route + `Page.Search` UI), user-facing on completion.

## Feature-Completeness Pre-Check

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-1.5.2 — Deep search (BACKEND) | `search_controller.ex:31` parse `scope=deep` → `books.ex:698` `search_books(scope: :deep)` (title_tsv OR description_tsv, title-ranked) → `books.ex:769` `description_snippets/2` (ts_headline `<mark>`) → `shelving.ex:197` `search_collection(scope: :deep)` → `proto_json.ex:140` `search_hit` snippet field 6 | Elixir tests drive it (213 green incl. deep-scope + snippet + ranking + collection) | ✅ backend | Backend contract shipped |
| US-1.5.2 — Deep search (ELM/UI) | `Api.searchBooks query deep token` appends `&scope=deep` (Api.elm) → `Page.Search` `DeepSearchToggled Bool` re-fires book search under new scope → `viewDeepSearchToggle` checkbox (testId `deep-search-toggle`) → `snippet` on `CollectionHit`/`PlatformHit` → `viewSnippet`/`parseSnippet` render `<mark>` runs as styled `<mark>` elements + "via deep search" label | LIVE on :4000 (both deep specs GREEN, 4 passed / 5.8s): seeded a public book whose DESCRIPTION carries a unique term (via `POST /api/test/book-description`); with the toggle OFF a description-term query returns the book absent; **checking "Deep search" surfaced the book with a `.search-result__snippet` whose `<mark>` wraps the matched term and a "via deep search" label** — observed in the DOM. A TITLE-term query under deep returns the book with NO snippet/label. Also: toggle re-fire fired `GET /api/search?q=book&scope=deep` (observed); 17/17 non-deep search specs green (no regression). | ✅ built end-to-end + observed live | Complete |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements
- Migration: `description_tsv` tsvector column on `op.books` (generated or trigger-maintained, matching the existing `title_tsv` pattern) + GIN index. Proto field addition via `proto/persisted.exs` + `mix proto.sync` if the column is exposed.
- `Stacks.Books.search_books/2` (or a new `search_deep/2`): `plainto_tsquery('english', ?)` against `description_tsv` (and review-summary source when available), `ts_headline` snippet in the result payload.
- `SearchController.index/2`: accept `scope=deep`; default remains title-only. Visibility filtering (`Visibility.can_view?/2`) applies identically.
- Elm `Page.Search`: `searchScope` model field + toggle, snippet rendering, "via deep search" label on deep-matched results.
- 13-layer coverage for the new behaviour (its own test audit when picked up).

## Reviewer Context
- Search sanitiser strips non-word chars (`String.replace(query, ~r/[^\w\s]/, "")` in `books.ex`) — deep search must keep injection-safety parity.
- dbt staging models and Ecto schemas are proto-generated (`mix proto.sync`); do not hand-edit.

## Test Audit

_Compact audit (format A) — the 13 layers, each `yes` (✅ + a test citation verified by grep/Read against the shipped suites) or `n/a`-with-rationale. Deep search is a backend query slice (`scope=deep` over `description_tsv` + `ts_headline` snippets) with an Elm toggle/snippet renderer; it adds no new endpoint, auth surface, event, job, or persisted-for-dbt data._

Last generated: 2026-07-25 (post-implementation compact audit)

Legend: ✅ = real coverage | n/a = not applicable (one-line reason).

| Layer | Applies? | Verdict |
|-------|----------|---------|
| 1. API calls | yes | ✅ `search_controller_test.exs:369` (scope=deep surfaces a description-only match with a highlighted snippet), `:385` (default scope does NOT surface a description-only match), `:401` (title-only hit under scope=deep carries an empty snippet), `:416` (deep scope applies to the collection section with a snippet), `:436` (SearchHit always carries a snippet field, empty by default); additive contract `SearchHit.snippet = 6` (`proto/stacks/api/v1/book_responses.proto:121`). |
| 2. Auth & middleware guards | no | n/a — `scope=deep` adds no new guard; the `/api/search` 401 + visibility gate is unchanged and validated under #115 (`search_controller_test.exs:94`). |
| 3. Database interactions | yes | ✅ `books_test.exs:332` (deep finds a description-only match), `:350` (title-only default ignores description), `:363` (deep ranks a title match ahead of a description-only match), `:392` (populates `description_tsv` on creation), `:408` (query uses the `description_tsv` GIN index), `:423` (`description_snippets/2` returns a `<mark>` excerpt), `:437` (omits title-only hits); migration `20260724120000_add_books_description_tsvector_column.exs` (generated `description_tsv` + GIN index). |
| 4. Event flow & lifecycle | no | n/a — search is a read path and emits no events (US-1.5.2 §6). |
| 5. Background jobs (Oban) | no | n/a — no Oban job in the deep-search read path. |
| 6. External service calls | no | n/a — `description_tsv`/snippets derive from stored catalogue metadata; no external call at query time. |
| 7. Storage | no | n/a — no storage operation on the search read path. |
| 8. Cache | no | n/a — search is uncached by design (#115 audit precedent). |
| 9. dbt models | no | n/a — `description_tsv` is a generated column, not mapped in `persisted.exs`/dbt (like `title_tsv`); no dbt model change. |
| 10. Elm frontend state machine | yes | ✅ `SearchTest.elm:198` `snippetParser` (5 cases: happy/multiple/no-marks/malformed/empty), `SearchProgramTest.elm:789` (deep-matched hit renders its snippet + "via deep search"), `:807` (a `<mark>` run renders as a `<mark>` element), `:827` (title match renders no snippet/label), `:75`/`:77` (deep toggle re-fires with/without `scope=deep`); E2E `search.spec.ts:682`/`:725` (deep-only surfacing + highlighted snippet live; title match carries no snippet). |
| 11. Operational metrics | no | n/a — covered by the SLO gate (`scripts/check-slo-gate.sh`). |
| 12. Performance & usability | no | n/a — SLO gate; in-test latency bounds are a CI anti-pattern. |
| 13. Cost tracking | no | n/a — deep search is a local Postgres query; no external API spend. |

Tally: 3 ✅ / 10 n/a — 0 ❌, 0 ⚠️. GREEN.

## Definition of Done
- [x] Deep search returns description/review matches with snippets (BACKEND) — evidence: `search_controller_test.exs:365` (scope=deep surfaces description-only match w/ `<mark>` snippet), `books_test.exs:331` (deep finds description-only book), `:392` (ts_headline snippet), `:350` (default ignores description). 213 scoped tests green.
- [x] Title-only default behaviour unchanged — evidence: `search_controller_test.exs` "default scope does NOT surface a description-only match"; existing #285/#229 search tests still green (213/0).
- [x] Contract additive `snippet = 6` on SearchHit — evidence: `book_responses.proto:117`, `buf lint` green, `proto.sync --check` clean, `gen-elm-proto` regenerated, `elm-test` 1042/0.
- [x] Migration mirrors title_tsv (generated `description_tsv` + GIN) — evidence: fresh-DB migrate-from-scratch on isolated partition → `description_tsv ALWAYS` generated col + `idx_books_description_tsv`, seeds green. squawk/lint-migrations clean (DSL form, `concurrently:`).
- [x] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — backend ✅ (213/0) + Elm/UI ✅ built end-to-end and observed live: both deep E2E specs GREEN on :4000 (4 passed / 5.8s), the toggle surfaces a description-match with a highlighted `<mark>` snippet + "via deep search" label in the DOM; a title-match under deep shows no snippet.
- [x] Every backend behaviour has a validation path (context + controller test layers).
- [x] Deep-search toggle + snippet rendering built with tests (`Api.searchBooks` scope param, `Page.Search` `DeepSearchToggled` + `parseSnippet`/`viewSnippet`) — evidence: `elm-test` **1056/0** (was 1042; +14: 3 toggle-flag + 5 `parseSnippet` unit + 6 program-test for re-fire/scope/snippet-render); test-first (5 captured failing on the stub, then green); elm-format/elm-review/`elm make --optimize` clean; e2e `search.spec.ts` "Deep search (#284)" 2 specs GREEN live.
- [x] Tests written and passing (`mix test` 213/0 scoped; `elm-test` 1056/0; e2e search.spec.ts 19/19 live incl. 2 deep).
- [x] Standards compliance verified (`just verify` passes) — format/credo/proto/squawk clean for backend diff; full `just ci` gate to run at epic integration. — evidence: `just verify` green on branch tip 2026-07-25 — elixir 2931 tests/0 failures, elm 1056/0, dbt 237/237 (scratchpad/verify-head-post284.log; sources.yml gap it caught fixed in 6fbe066c); `just ci` green on CVE-patched tip 2026-07-25 — all groups pass except dockle (no local Docker daemon, documented env limitation; CI has Docker); npm audits 0 vulns both trees, Trivy clean (scratchpad/ci-final-tip.log)
- [x] **Test audit is GREEN** — compact audit generated + citations verified 2026-07-25 (this section).
- [x] **`completion-audit` skill passed on the integrated branch** — after Elm phase. — evidence: epic completion-audit PASS 2026-07-25 — adversarial spot-verification of all 16 children found zero false evidence tokens; its 3 finalization blockers cleared (CVE fix 32b2a18c + ci green, compact audits 8eaf4bb6, preview E2E below)
- [x] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — after Elm phase. — evidence: Completion Bar met at epic level 2026-07-25 — every deliverable driven live locally (per-issue Pre-Check) AND on the deployed preview: full run 250 passed/10 failed/10 skipped (all 10 failures = helper-502 machine-churn signature) with all 10 passing the single documented environmental retry (12/12, exit 0); logs scratchpad/preview-e2e-run2.log + preview-e2e-retry10b.log

## Dependencies
- Issue #115 (search E2E hardening — lands the deterministic search E2E harness this feature will extend)
- Review-summary data source (Components.ReviewSummary pipeline) for the review slice

## Agent Assignment
`elixir-agent` + `database-agent` (migration/tsv) + `elm-agent` (toggle/snippets).

## Progress Notes
- 2026-07-23 — Created at #115/#114/#113 epic kickoff: US-1.5.2 de-scoped from #115 (feature entirely unimplemented; #115 is test-only).
- 2026-07-24 — BACKEND phase complete (elixir/database/protobuf). Added generated `op.books.description_tsv` + GIN index (migration `20260724120000`, DSL/`concurrently:` form for squawk parity with title_tsv). Extended `Books.search_books/2` + `Shelving.search_collection/3` with `scope: :deep` (title_tsv OR description_tsv, title-ranked-first), `Books.description_snippets/2` (`ts_headline` `<mark>` excerpts), additive `SearchHit.snippet = 6`, controller `scope=deep` threading snippets to both sections. Test-first: 7 new deep-behaviour tests captured failing (logic neutered) then green. Gates: 213 scoped Elixir tests / 0, elm-test 1042 / 0, `proto.sync --check` clean, buf lint + proto drift clean, format + credo clean, squawk 0 issues, lint-migrations clean, fresh-DB migrate+seeds proven on isolated partition. GDPR: PASS — `description_tsv`/snippet derive from book catalogue metadata (Open Library/Google Books), no PII, no new user FK, not mapped to persisted.exs/dbt/event_log/audit; visibility filtering unchanged. Elm toggle/labels are a separate later phase.
- 2026-07-24 — ELM/UI phase built + gated. `Api.searchBooks` now takes a `deep : Bool` and appends `&scope=deep` only when set (default wire URL byte-identical); `snippet` surfaced on `CollectionHit`/`PlatformHit`. `Page.Search`: added `deepSearch` model field + `DeepSearchToggled Bool` (re-fires the current query under the new scope, book-search only), a "Deep search" checkbox (testId `deep-search-toggle`, off by default), and `viewSnippet`/`parseSnippet` — a pure `<mark>` parser (balanced pairs → styled `<mark>` elements via the safe `text` API, never innerHTML; malformed/unbalanced input passes through verbatim as plain text) — plus a "via deep search" label, rendered iff `snippet` non-empty. Test-first: scaffolded with a stub parser + no-op toggle + no snippet render, captured 5 failing (parser happy/multiple/empty; snippet render; `<mark>` render), then implemented → green. Gates: **elm-test 1056 / 0** (was 1042; +14: 3 toggle-flag + 5 parser + 6 program-test), elm-format `--validate` clean, elm-review clean, `elm make --optimize` clean (44 modules, 0 warnings), e2e vacuous-guard check clean. LIVE on :4000: my Elm is in the served `app.js`; checking the toggle fired `GET /api/search?q=book&scope=deep` (observed); `search.spec.ts` 17/17 non-deep specs green (no regression from the toggle). Added 2 deep E2E specs (`Deep search (#284)`: description→highlighted-snippet+label, title→no-snippet) that assertSeedOrSkip until the `POST /api/test/book-description` seed helper lands (no seeded book carries a description — verified 0/169). Requested that helper from the backend agent; deep specs pass live once it exists. CSS: `.deep-search-toggle`, `.search-result__snippet`, `.search-result__mark`, `.search-result__via-deep` added.
- 2026-07-25 — ELM/UI deep E2E PROVEN LIVE. Backend shipped `POST /api/test/book-description` (`9ece4160`); restarted the shared :4000 through the pinned toolchain (`just run mix phx.server`, env `AGE_GATING_ENABLED=true STACKS_E2E_TEST_HELPERS=1 MIX_ENV=dev`) — dev has `code_reloader` off so the new route needs a restart. First live run surfaced a spec bug (not a deep-search bug): a freshly-minted, placement-free viewer gets the global onboarding overlay whose backdrop eats the toggle click. Fixed both specs to place a shared-seed book first (the gdpr/privacy/audit-log onboarding-suppression pattern) + assert the overlay is gone before interacting. **Re-run GREEN: `search.spec.ts -g "Deep search"` → 4 passed / 5.8s** — (1) description-only match: toggle OFF → book absent; checking "Deep search" → book surfaces with `.search-result__snippet` whose `<mark>` wraps the matched term + a "via deep search" label (observed in DOM); (2) title match under deep → book present, no snippet/label. Full `search.spec.ts` remains 17/17 on the non-deep specs (no regression). Feature-Completeness Pre-Check now ✅ for US-1.5.2 (backend + Elm/UI, observed live). Left `just verify` / test-audit / completion-audit / Completion-Bar boxes for epic integration.
