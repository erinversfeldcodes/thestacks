# Issue #323: W0 child B — Config/ops: metrics scrape auth, EMAIL_FROM, smoke-test flag

## Summary
Child of epic #311. Three config-as-code fixes: the preview/prod metrics source 401-ing `GET /internal/metrics` every 15s; `EMAIL_FROM` unset (prod transactional email cannot deliver per `config.exs:210-218`); `SMOKE_TESTS_ENABLED` set unconditionally by `deploy-stack.sh:898` against `runtime.exs:106`'s documented "never in production".

## User Stories
None — ops. Validation = live signals on a preview stack + documented owner action for prod secrets.

## Goal
Metrics collection authenticates (no 401 loop in preview logs); `EMAIL_FROM` is wired through deploy config with the prod value documented as an owner-applied secret; smoke-tests flag only set outside PROD_MODE.

## Scope Check
Scripts + config + runbook only. No split.

## Wiring
Router wiring: n/a.

## Feature-Completeness Pre-Check
n/a — no user stories.

## Technical Requirements
- **0a**: diagnose why the metrics agent's scrape of `/internal/metrics` 401s (ADR-021 push pipeline; evidence `preview-core.log 23:14` — polling every 15s, rejected). Likely the internal-token header missing from the vmagent/scraper config in `deploy/` — find the authoritative config, fix, and ensure preview + prod stacks both get it.
- **0b**: plumb `EMAIL_FROM` (fly secret) through `scripts/deploy-stack.sh` prod path + `.env.example` + the email-delivery runbook (`docs/runbooks/email-delivery-failure.md`). DO NOT set the prod secret yourself — document the exact command for the owner; stage it for preview if a test sender exists.
- **0c**: wrap the `SMOKE_TESTS_ENABLED` export at `deploy-stack.sh:898` in the non-PROD conditional (match how `STACKS_E2E_TEST_HELPERS` is gated at `:314`).

## Reviewer Context
- Mode E never deploys to production — prod secret application is an owner op; the deliverable is config-as-code + runbook.
- The X-Internal-Token HMAC (`internal_controller.ex:78`) currently mitigates 0c — the change enforces the documented invariant, not a live hole.
- Preview redeploy to verify 0a is allowed (preview deploys are in-scope); coordinate with the epic lead — one redeploy at finalization covers all children.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Ops/live | yes | ❌ preview logs show `/internal/metrics` → 200 after redeploy; ❌ `deploy-stack.sh` dry-run/grep proof for 0b/0c wiring |
| 1–13 | no | n/a — scripts/config |

## Definition of Done
- [x] 0a landed — evidence: dead `[metrics]` scrape block removed (root cause: Fly platform scraper cannot send auth headers; ADR-021 obsoleted the path); finalization preview logs 2026-07-30: **0** `/internal/metrics` 401 lines over 4-min capture (was: one every 15s)
- [x] 0b wired — evidence: `deploy-stack.sh:867` secret plumb + `:827` prod-mode WARN with exact owner command; `.env.example:181`; runbook Step 5 added (grep proofs in build report)
- [x] 0c gated — evidence: `deploy-stack.sh:294` PROD forces empty, `:889` prod purge of previously-staged secret; repo-wide grep confirms sole setter
- [x] shellcheck-clean — evidence: identical finding-set before/after (all pre-existing, none in edited regions); `just ci` elixir/lint groups PASS
- [x] `staff-review` verdict recorded below — evidence: LGTM WITH NOTES, Progress Notes 2026-07-30 (notes → #320)
- [x] Scope addition: cleanup-preview pipefail fix — evidence: 56a43dbe; retried deploy tore down/rebuilt cleanly (deploy-w0-final3.log all PASS)

## Dependencies
Epic #311. No sibling dependencies.

## Agent Assignment
elixir-agent (ops-leaning).

## Progress Notes
Filed 2026-07-30 (Wave 0 kickoff approved).
Built in worktree; commit 29de3314; merged to feat/campaign-w0-311 (re-merged 4c461444 after base correction).
Scope addition (discovered mid-epic, 2026-07-30): `cleanup-preview.sh` drain step died under pipefail when the core app doesn't exist (first deploy of a new branch name) — fixed in 56a43dbe on the integration branch, folded into this issue's ops scope.
**staff-review verdict: LGTM WITH NOTES** (2026-07-30, Mode B on 29de3314). Praise: the 0a investigation chose removal over token-wiring and argued it from evidence (Fly's `[metrics]` scraper cannot send headers; ADR-021 made the scrape path dead; #248 confirmed zero ingestion) — the right fix is deleting the lie, and the runbook was rewritten to match. Purging the wrongly-staged prod `SMOKE_TESTS_ENABLED` secret on next deploy shows whole-chain thinking. Notes (🟨, ledger → fold into #320): `MetricsAuth`'s 6PN bypass + `endpoint.ex:43`/`runtime.exs:120-126` comments still reference the retired Fly scrape; `scripts/dashboard-smoke.sh` still targets it. Live-signal evidence (metrics 200 on preview, EMAIL_FROM warn path) lands at epic finalization drive.
