# Issue #311: [EPIC] Campaign Wave 0 — Eight small fixes with outsized payoff

## Summary
Epic for Wave 0 of `plans/staff-campaign-2026-07-30.md`: eight independent, design-free fixes, each closing a live defect found in the 2026-07-30 walkthrough. Orchestrator spins children per phase (Epic Parallel Execution); phases are independent and fully parallel.

## User Stories
US-1.1.1 (0e upload), US-17.3.1 (0h notifications), US-14.3.3 (0f header) — remainder infra (validation paths still required).

## Goal
All eight defects closed and re-driven live on a preview: no `/internal/metrics` 401 loop; prod email deliverable; smoke-tests flag honours its documented prod invariant; rate-limited scrape outcome handled (price retry-storm stops); 0-byte uploads rejected before the GPU; header no longer reflows on menu open; reading-pile status card anchored; tokenless Notifications shows NotAsked, not eternal Loading.

## Scope Check
Epic — scope rules apply to the children, not the epic. Each phase below is well under the 300-LOC/3-controller bar; none combine concerns.

## Wiring
Router wiring: no new routes; 0e/0f/0g/0h are user-facing behaviour fixes on existing surfaces, rest are config/ops.

## Feature-Completeness Pre-Check
n/a — epic of defect fixes on already-built surfaces; each child's live re-drive is the check.

## Technical Requirements (child phases, in `child_order`)
1. **0a metrics-auth**: fix the credential/config so the preview/prod metrics push source stops 401-ing `GET /internal/metrics` every 15s (see ADR-021 pipeline; evidence: `preview-core.log 23:14`).
2. **0b EMAIL_FROM**: set the env in prod secrets; `config.exs:210-218` documents this as the only remaining step for deliverable prod email. Add to deploy runbook.
3. **0c SMOKE_TESTS_ENABLED**: `scripts/deploy-stack.sh:898` sets it unconditionally against `config/runtime.exs:106`'s "never in production". Wrap in the non-prod conditional.
4. **0d RATE_LIMITED clause**: `trigger_price_scrape_job.ex` gains a `SCRAPE_OUTCOME_RATE_LIMITED` clause mirroring ROBOTS_BLOCKED (`{:determined, :rate_limited}` + `Monitoring.record_success/2`) — interim until #314's enum codegen. Provenance: commit `f28c032e` missed this consumer.
5. **0e 0-byte gate**: `Books.verify_object_exists/1` (`books.ex:489-495`) matches `{:ok, size} when size > @min_image_bytes`; reject with a distinct error the SSE stream surfaces. Companion magic-byte sniff in `store_upload_bytes/2` optional.
6. **0f header reflow**: delete the inline `style "position" "relative"` in `Components/UserMenu.elm:93-98` (inline style defeats `.app-nav__dropdown-menu`'s `position: absolute`).
7. **0g reading-pile panel**: move `viewProgressPanel` out of `.reading-pile__scene`'s flex row to a sibling after it (`ReadingPile.elm:323`); its CSS (`main.css:4446`) is already written for that position.
8. **0h Notifications init**: return `NotAsked` + `Cmd.none` when tokenless (`Notifications.elm:37-46`), matching `AuditLog.init`'s correct handling.

## Reviewer Context
- Preview core VM is 512MB; release tasks via `rpc`, never `eval`. Bare `mix` corrupts `_build` — `just run` everything.
- 0d intentionally duplicates logic the enum codegen (#314) later makes structural; land it anyway — prices have produced zero rows for three campaigns.
- 0f: one-line deletion; verify the second bug noted in the campaign (menu invisible unless trigger holds focus — `:focus-within` coupling) separately; do not scope-creep it here.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| External service calls (0a,0b,0d,0e) | yes | ❌ 0d: RATE_LIMITED interpret test; 0e: reject-empty test (`upload_pipeline_test.exs`); 0a/0b verified by live signal (metric landed / email delivered) |
| Elm state machine (0f,0g,0h) | yes | ❌ 0h: tokenless-init test; 0f/0g: live-drive screenshots (layout claims — browser evidence, not unit) |
| Oban jobs (0d) | yes | ❌ no-retry-on-rate-limited assertion |
| Other layers | no | n/a — config/one-line fixes; SLO layers covered by gate |

FINAL (2026-07-30): (1) ✅ RATE_LIMITED tests ("a rate-limit is a determination…", "…does not retry") 17/0; (2) ✅ empty-object tests + live 422 + browser failure state ss_7712fzukt; (3) ✅ NotificationsTest tokenless→NotAsked, probed; (4) ✅ live drives: ss_4933q9aro/ss_2563sec80 (no reflow), panel anchored, 0 metrics-401 lines in 4-min capture. AMENDED at completion-audit: "one delivered email" was over-scoped — delivery is owner-gated prod action (runbook Step 5); wiring proven by grep + prod-mode WARN path. Verdict: GREEN with that named deferral.

## Definition of Done
- [x] All 8 phases closed with evidence — evidence: child DoDs #322/#323/#324 (each box carries its token, 2026-07-30)
- [x] Price scrape clean — evidence: 4-min finalization log capture: 0 `unrecognised outcome` lines; RATE_LIMITED logged as info-level determination ("asked us to back off; 17s remaining"), no retry storm
- [x] 0-byte live — evidence: API drive → 422 `image_too_small` + server log line; BROWSER drive: empty-file drop on /upload → "Upload failed. Please try again." + Try Again within seconds (ss_7712fzukt — was: infinite spinner); probe 147/3→147/0. (Distinct per-cause copy = Wave 7 scope.)
- [x] Validation paths per behaviour — evidence: child audits (0a live log absence; **0b config-grep + WARN path only — no live email: delivery is owner-gated prod scope, owner command documented in runbook**; 0c grep; 0d/0e/0h tests+probes; 0f/0g screenshots)
- [x] Tests passing — evidence: elixir scoped 164/0 + 147/0 + 17/0; elm 1176/0; `just ci` elixir/elm test groups PASS
- [x] Standards — evidence: `just ci` 14/16 groups PASS; squawk re-verified green after 9dbfb9fa; security = sobelow+Trivy clean, dockle local-daemon limitation (documented exception, CI has Docker)
- [x] Test audit GREEN — evidence: all 4 punch items delivered (RATE_LIMITED tests, empty-object tests, tokenless-init test, live screenshots/log signals); no ❌ remaining
- [x] `completion-audit` passed — evidence: run 2026-07-30, recorded in Progress Notes below
- [x] Completion Bar — evidence: every fix re-driven live on the finalization preview (screenshot pair + panel + API 422 + log absences); 0 `[error]` lines during drive; tracking (epic+campaign state) regenerated
- [x] `staff-review` per child — evidence: verdicts in #322 (LGTM), #323 (LGTM WITH NOTES), #324 (LGTM) Progress Notes

## Dependencies
None — this epic is first precisely because each phase is independent and unblocks nothing/nobody else's design.

## Agent Assignment
Orchestrator (Epic Parallel Execution); children route to elixir-agent (0a–0e) and elm-agent (0f–0h).

## Progress Notes
Filed 2026-07-30 by staff-campaign Stage 7. State: `plans/staff-campaign-2026-07-30-state.json` wave 0.
**completion-audit: PASS** (2026-07-30). The adversarial sweep found and closed three over-claims before clearing: (1) 0e's user-visible failure had only API evidence → browser drive added (empty-file drop → "Upload failed" + Try Again, ss_7712fzukt); (2) 0b's token implied a delivered email → corrected to config-scope with the named owner deferral (runbook Step 5); (3) the embedded audit table was stale baseline → regenerated. Spot-checks: cited test strings verified by grep (1 hit each); phantom-ref sweep clean (#316/#320/56a43dbe/9dbfb9fa all real); reviewer notes routed to #320 §4a; logs clean (0 errors, 4-min capture under drive); integration gate 14/16 + squawk re-verified + dockle local-daemon exception documented. Wave 0 marked complete in campaign state; `wave-status --wave 0`: all claims backed.
**staff-review (epic cumulative, Mode B): LGTM** — the branch diff is the three reviewed children + two discovered fixes, each already probed; no cross-child interaction surface (disjoint files).
