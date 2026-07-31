# Issue #313: [EPIC] Campaign Wave 3 — Test architecture

## Summary
Epic for Wave 3 of `plans/staff-campaign-2026-07-30.md`: make green mean something before the refactor waves move code. Probe-proven headline: all five production SSE wire-format fields were broken and 1,285/1,285 Elm tests stayed green.

## User Stories
None — test infrastructure. Every change validated by a mutation probe that now REDDENS where it previously stayed green.

## Goal
Fixtures can only encode states production can produce; the vision seam is steerable; no mock compiles into the release; the SSE wire format is single and guarded; the named unfalsifiable/echo tests are rewritten or removed with coverage notes.

## Scope Check
Epic; children per phase below, each single-concern.

## Wiring
Router wiring: none — test/support and config surface only (one prod-visible change: mocks leave `lib/`).

## Feature-Completeness Pre-Check
n/a — no user stories.

## Technical Requirements (child phases)
1. **Factories through changesets/public API** (`factory.ex`, 512 lines, no `insert/2` override): book factory must create an edition (ISBN gate); ISBN sequence emits checksum-valid values; placement factory derives shelf from bookshelf (kills the universal desync); user factory routes register→confirm for confirmed users or explicitly overrides. Expect and fix legitimate fallout across suites.
2. **Vision seam**: give `Stacks.AI.MockClient` the steering API its moduledoc already claims (`put_response/2` keyed by endpoint); delete the five ad-hoc replacement modules in `upload_pipeline_test.exs`/`books_test.exs`/`ai/client_test.exs`; move ALL mocks from `lib/` to `test/support` (11 of 13 currently compile into prod; `MockReviewFetcher` handled by #312).
3. **Wire format**: server emits snake_case; delete the camelCase branches in `Api.elm:288-318`; regenerate/derive Upload SSE fixtures from `proto_json.ex` shapes; fix `TestHelpers.elm:619-628` (progress fields the proto doesn't define — coordinate with #314 if the proto gains them instead: one side must move); export `Api.elm`'s real decoders for tests, delete the 5+6 hand-mirrors.
4. **Named rewrites/removals** (each with a coverage note): `BookshelfReadOnlyTest.elm:233-241` SECURITY test gets a real effect translator + positive control; `rate-limit.spec.ts:86-89` fail-closed (assert 429, don't skip); mock-echo removals per the test-inventory list (searxng_client_test whole file, brave first describe, upload_pipeline `:1643-1692` block, transparency value-echoes, `books_test.exs:552-565`/`595-620` strengthened to assert real values); add the consumed-reset-token second-use test (`email_test.exs` — behaviour verified live 2026-07-30: replay → 400; the guarantee has no test); decide `:sla` tag (run it or delete it); fix `SessionExpiryTest.elm:108,130` `notEqual NoOut` weak assertions.

## Reviewer Context
- Mutation-probe protocol is the acceptance instrument: each child's DoD cites a probe that FAILS after the fix (was green before). One probe at a time; revert via Edit, never `git checkout`; `git diff --stat` clean before any report.
- `MockHttpClient` doc says first-registration-wins; code is last-wins (`:34-37`) — fix doc or code while in there.
- `elixirc_paths(:test)` change (mocks→test/support) can break `config.exs` references in non-test envs — the config keys must move to `test.exs` only.
- Elm has no test-only exposing: exporting decoders widens `Api.elm`'s surface deliberately; note it in the module doc (project convention: `Msg(..)` exposure for tests is accepted — see memory).

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Meta (probes) | yes | ❌ probe battery: SSE-field break must redden ≥1 test; editionless-book fixture must be unconstructable; desynced placement unconstructable; read-only test reddens on a mutating effect; rate-limit spec fails (not skips) with limiter off |
| Suites | yes | ❌ full green after each child at cited counts |
| 1–13 | no | n/a — test-infra epic |

Punch: the five probes above + coverage note per removed test.
Verdict: baseline ❌ — the probe battery IS the exit criterion.

## Definition of Done
- [x] All 4 phases landed; probe battery run with verbatim output — evidence: #327 steering+$callers, #328 six-field × 16 red, #329 8 impossibility probes + 14 guard rails, #330 three falsifiability probes (SECURITY / rate-limit counterfactual / reset-token replay). Lead independently re-probed one per child.
- [x] No module under `lib/` matches `Mock*` — evidence: `grep -rl "defmodule.*Mock" apps/core/lib` → 0 (lead-verified at wave gate); MIX_ENV=prod 266 files vs test 281
- [x] Coverage note per removed/rewritten test — evidence: in-file at each #330 site; #329 category-level repair notes
- [x] Suites green — evidence: `just ci` 15/16 groups PASS at wave gate (elixir 3,206/0 · elm 1,332/0 · squawk · licenses); only the standing dockle local-daemon exception
- [x] Test audit GREEN — evidence: every ❌ in the four child audits delivered; the wave's own acceptance instrument (probe battery) is green
- [x] `completion-audit` passed — evidence: 2026-07-30 run, Progress Notes below
- [x] Completion Bar met — #328 changed production decode behaviour (`Api.elm` SSE path), so a live drive WAS required and performed on preview: see Progress Notes. Remaining children are test-only (production diff empty for #330, zero lib/ lines for #329).
- [x] `staff-review` verdict per child — evidence: #327 LGTM, #328 LGTM, #329 LGTM, #330 LGTM, each with an independent reviewer probe

## Dependencies
- #312 (deletions) — never harden tests around code being removed. Reason: sequencing rule 1.
- MUST precede #314/#315/#316 — guarantees before the refactors that need them (sequencing rule 3).

## Agent Assignment
Orchestrator; children to elixir-agent, elm-agent, e2e-focused agent.

## Progress Notes
Filed 2026-07-30 by staff-campaign Stage 7. Four children built in isolated worktrees across 3 dependency levels; merged 541d1471 / e6030b9a / 13f41f41 / 10979820 into `feat/campaign-w3-313`.
**LIVE DRIVE (required by #328's production change, performed 2026-07-30 on preview `stacks-core-pr-feat-campaign-w3-313`):** the point of doubt was that #328 made `Api.elm`'s SSE decoder *strict* — six required snake_case fields where it previously accepted either shape — so unit tests prove it accepts what `proto_json.ex` claims to emit, but only a real upload proves what the server actually sends (including heartbeat frames, which now deliberately fail decode and fall to the `Err _ -> ignore` branch). Drove the full loop: dropped `barcode_isbn_clean.jpg` (SHA-256 verified) → "We think this is… The Name of the Rose / UMBERTO ECO" with cover (ss_865789odj) → confirm → shelf picker (ss_0712zdycb) → Antilibrary → *"The Name of the Rose" added to Antilibrary* (ss_31505f6j8). API confirms `[{shelf: antilibrary, title: The Name of the Rose}]`. **Preview logs during the drive: 0 `[error]` lines, 0 decode/malformed/unexpected lines**; `IdentifyBookJob` also resolved a 5-book multi-ISBN canary cleanly. The strict decoder is correct against the real wire.
**completion-audit: PASS** (2026-07-30). Adversarial sweep: (1) the epic's own Completion-Bar box originally read "no live-drive deliverable here" — challenged and **corrected**, because #328 changed production decode behaviour; the drive above is the result, and that box now says so; (2) every ✅ traced to a probe transcript, a command→output, or a screenshot — no bare claims; (3) phantom-ref sweep clean (#314/#331/#332 all backed by real files); (4) no dropped scope — all four children delivered their named items, with three spec corrections *by* the children recorded in the review notes rather than quietly absorbed; (5) discovered work was filed, not buried (#331, #332, both now assigned to Waves 5 and 6 by owner ruling); (6) the one unexplained failure #330 flagged did not recur across three subsequent full runs including the wave gate, and is recorded rather than dismissed.
**staff-review (epic cumulative): LGTM** — 52 files, +1,796/−906 across 8 commits; four independently-probed children, no cross-child interaction surface beyond the seam #327 built and #329/#330 consumed as intended.
**PR deferred by owner ruling** — all wave PRs batch until the final wave; branch stays local, stacked on `feat/campaign-w2-312`.
