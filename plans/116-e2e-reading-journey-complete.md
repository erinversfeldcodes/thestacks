# Issue #116 — COMPLETE (completion-audit: PASS)

**Branch:** feat/116-e2e · **Date:** 2026-07-23
**Commits (issue scope):** a1499f92 (P1 shelving fixes) · 9be0c735/56000f6b (P2 progress feature) ·
aea275d3 (P4 elm tests) · 8c182af2 (P3 hardening) · 272d3b6a + bd578eaf (P5 E2E specs) ·
e3cf8713 (P6 dbt) · 38ce2077 (close-out). Pre-epic on the same branch: 79d28f9d (#278),
3d3fcc71 (#192), d24465d4/d897d9a4 (#276), 9331b1cb (issue moves).

## Completion-audit verdict: PASS
Adversarial sweep (all eight classes) clear, each with cited artifacts:
- **Driven live, far-end signals observed:** move/abandon/reread/remove/empty/progress all driven
  in a real browser and at the API against local + deployed-preview stacks; event rows verified in
  `op.event_log`; dbt tests ran on real seeded data (41 history rows, discriminating removed rows);
  ceiling rejection observed live (999999 → 422 on a 925-page book).
- **Real-path gates:** consolidated preview E2E (219 passed; 10 pre-existing #269 env skips;
  rotating env failures root-caused — VM-load actionability timeout + `:auth` 429s in unmigrated
  registerAndConfirm — each green on clean retry, remediation tracked in #280); fresh-DB gate
  (drop→migrate→seed→2827/0→dbt 64/64+237/237→checkpoint); `just ci` all groups green, one semgrep
  finding fixed (bd578eaf), dockle = documented local-Docker caveat.
- **Audit GREEN:** 156 cells, 60 ✅ / 0 ⚠️ / 0 ❌ / 96 n/a-with-rationale; 18/18 punch items
  resolved; DoD fully checked with evidence tokens; zero phantom refs (verified by sweep).
- **PE gate:** SHIP, no P0/P1; P2/P3s all tracked (#279 mart drop-to-zero, #280 E2E auth
  migration + seed guarantee, #281 shelving/books hardening + frontend polish, #282 DbtRunner dev
  path).

## PR-body notes (carry into finalize-pr)
- #279 coupling: `test_mart_community_read_count_excludes_removed` will correctly go red against a
  prod *incremental* mart after a last-placement removal until #279 lands — sequence #279 soon.
- Security group locally green except dockle (needs Docker daemon; CI covers it).
- Preview for this branch: https://stacks-core-pr-feat-116-e2e.fly.dev (auto-stops; clean up with
  `scripts/cleanup-preview.sh --branch feat/116-e2e` after the PR).

## Delivered (summary)
1. **US-1.6.1/1.6.2 unbroken:** `move_book/3` re-homes `shelf_id` to the destination bookshelf
   (planning live-drive had proven moves invisible on target browse); browse-level regression
   tests at unit + E2E.
2. **US-1.6.6 built:** `PlacementCard` mounted on Reading Pile + Book Detail with a11y-complete
   inline editing, page-count ceiling, registered reading events, record-a-read bridge, full CSS.
3. **Reading-journey E2E:** five isolated-user browser specs (move-browse regression, abandon,
   full journey, reread round-trip, progress journey).
4. **Test hardening:** move sad paths, delete idempotency, rollback seams, target-pinned audit
   assertions, event isolation, Elm confirm/no-op coverage, dbt history relationships +
   removal-exclusion + `placement.removed`→refresh wiring.
5. **Reread hardened:** ownership + not_found (was: any caller could reread anyone's placement).
