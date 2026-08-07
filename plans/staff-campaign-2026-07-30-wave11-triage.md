# Wave 11 triage digest (2026-08-07)

Read-only triage of all 22 children by 5 cluster readers. Verdicts grounded in code + preview DB/API.

## ALREADY-FIXED → verify-and-close (no build; doc lag)
| # | Fixed by | Residual |
|---|---|---|
| #370 every-book-not-identified | 6f54a28d (Elm split, deployed) | record legacy-row disposition (declined+reasoned); run 2 search.spec.ts titles. **Do NOT redo Elm.** |
| #372 four deterministic E2E fails | 630961cf | all 4 were SPEC defects; verify-close + 1 preview run |
| #371 admin MFA shared factor | babcc4be | staff-review box only. ⚠️ NEW: intermittent `mfa confirm` 422 on preview → **file new issue** |
| #380 book-detail worker-count | babcc4be | evidence sits in #371 notes; copy over + close. Distinct root cause from #371 (contention vs shared state) |
| #377 unit test live network | df170b48 | close (seamed via rss_fetcher) |
| #385 title-search outage cache | a2393586 (#352) | close (test landed 2 days before the issue was filed) |

## STILL-REPRODUCES → real work
**Launch-blocking correctness (live):**
- **#357** (M, Med) cached book defeats age-gate + enrichment. ⚠️ preview has AGE_GATING_ENABLED=true → 5-min stale-visibility window LIVE now. Fix: SYNC cache invalidation on set_visibility_tier + emit book.enriched from EnrichBookJob + handler clauses + registry/payload_contract + rewrite the false-guarantee test (upload_cache_test.exs:254-286 pre-seeds the gated value). **Must land before prod age-gating.**
- **#378** (M, Med-high) scanned edition never recorded (0/221 placements point non-primary). Thread edition through find_existing→place_book/4. ⚠️ Interacts with #376 un-merge test (asserts current "placements stay" rule) — revisit when this lands. Blocks principled #376.
- **#336** (M, Med) dead review vertical (0 rows, emitter removed 45ddcc44). **SCOPE DECISION.** int_review_sentiment feeds 3 marts (not 1). Highest-leverage: extend registry_completeness_test to inverse direction (catalogued⇒emit-site) — surfaces OTHER orphans.

**Auth/session/stability:**
- **#369** (M, Low-Med) Argon2 OOM config never landed. ⚠️ PROD still 2×512MB (live-vulnerable, currently suspended). Fix: raise fly.core.toml memory→1024 + readback gate + concurrency test. **COST DECISION (prod).** Blocks #163.
- **#367** (M, Low-Med) stale consent. Needs SERVER change first (consent not in any GET). GDPR-relevant.
- **#368** (M, Low-Med) reconnect no refetch — DELIBERATE documented decision; fix must scope refetch to current page. Lowest priority.

**GDPR/warehouse/security (all S, 0 P0):**
- **#338** P1 placement notes in warehouse → dbt_exclude. Batch w/ #386 (one proto.sync).
- **#386** P1 storage_path in warehouse → dbt_exclude. user_id currently unused (keep).
- **#392** P1 export omits blog posts/comments. **Erasure ALREADY reaches blog data (not P0).** Add to export.ex.
- **#393** P2 dead 6PN MetricsAuth bypass. Remove + INVERT the bypass test (metrics_auth_test.exs:68).

**Test hygiene / gates / a11y:**
- **#391** (S) orphan gate comment-strip. One line; measured ZERO masked orphans (risk-free).
- **#358** (S) warmup-guard test never terminates. ⚠️ BLOCKS run_all.sh (suite 15/17). Test stubs only.
- **#366** (M) no ports-wired gate + **2 LIVE orphan ports** (saveOnboardingCompleted/onOnboardingStatus) → onboarding re-triggers on reload. Split: gate + behaviour fix (needs drive).
- **#347** (M) program-test translators mirror Api (10 translators, 47 SimulatedEffect sites). Seam confirmBookRequest; fix uploadEffects' 5 branches.
- **#381** (L→split 5) unseamed Finch sites. 381a (books.ex:753 cover download) urgent+HIGH; 381b circuit_breakers; 381c rss_liveness (one-liner); 381d request_timeout everywhere; 381e the discovering gate.
- **#384** (M) no E2E for un-merge/merge. New chromium spec; #371 helpers satisfy the dep.
- **#388** (M) roving-tabindex a11y. Needs ↑/↓ design decision (nearest-x, pure fn over 990px pack). Sequence AWAY from Main's Escape/overlay-focus routing.

## NEW issues to file
1. Intermittent `mfa confirm` 422 on 1024MB preview (from #371 footnote) — MFA reliability, blocks admin-session/audit-log specs when it hits.
2. #366's two orphan onboarding ports (behaviour fix, wants a live drive) — child of #366.
3. (expected) #336's inverse-completeness test will surface a list of other registered-but-unemitted event types.

## Decisions for owner
- **#369 prod memory**: raise prod core VM 512→1024MB (doubles that VM's cost, 2 machines) vs preview-only-for-now (leave prod to #163). Prod is live-vulnerable but suspended.
- **#336 scope**: event-and-handler-only cleanup (keep dormant vertical + int_review_sentiment for 2 marts) vs full vertical removal (proto/table/models/marts — bigger, codegen).
- **#370**: decline the 4th verification enum value (keep S, record disposition) — recommended.
