# Issue #321: [EPIC] Campaign Wave 11 — Launch gates

## Summary
Epic for Wave 11 of `plans/staff-campaign-2026-07-30.md`: the net-new launch features (Milestones B–D), the prod deploy, and — per owner ruling 2026-07-30 — **wiring the bookstore-events vertical** rather than deleting it. Mostly re-points existing backlog items at the new stories from #320.

## User Stories
New stories from #320 (invite-only, Goodreads CSV, POSSE, FAQ, feedback) + US-2.4.1 (bookstore events, refreshed) + US-14.4.x interplay + #163/#066 runbooks.

## Goal
Registration is invite-gated; an invited user can import their Goodreads library; posts syndicate outward with canonical links; the platform runs on a real production domain with verified backups and a feedback channel; bookstore-event scraping produces real rows end-to-end.

## Scope Check
Epic; each feature is its own child (several are M/L alone — the orchestrator may split further).

## Wiring
Router wiring: new endpoints per child (register gating, CSV import, events read path) — each child states its own.

## Feature-Completeness Pre-Check
Baseline all ❌ by construction (net-new features); each child's pre-check fills at spin-out against its #320 story.

## Technical Requirements (child phases)
1. **Invite-only registration**: allowlist/invite-code gate on `POST /auth/register`; owner issues invites; open-registration path retired per the story; no-enumeration preserved.
2. **Goodreads CSV import**: CSV parse (title/author/ISBN/shelves/ratings/dates) → **through the ISBN hard gate** (import is just another capture source; junk still can't enter) → bookshelves + read/unread + placement history; provenance "imported from Goodreads"; one-directional; per-row failure report to the user.
3. **POSSE/Substack MVP**: canonical-tagged export + RSS-import route per the story (no write API exists — the constraint IS the design); `rel=canonical` back-links.
4. **Bookstore-events vertical (owner ruling)**: cron entry for `DiscoverBookstoreEventsJob`; replace the raw-regex extractor with the structured path (schema.org/Event → `.ics` → LLM fallback, per the research doc; egress via the compliant scraper path from the prior campaign's Wave 0c/0d); read endpoint from `Enrichment.Events`' currently-unused functions; surface events (book detail author section currently says "Events coming soon"); `op.bookstore_events` goes 0 → real rows on preview (zero-row sweep is the acceptance instrument).
5. **Prod deploy + safety floor**: execute #163's runbook on the real domain; backup/restore verification per #066; beta feedback channel (lightweight form/email per story).

## Reviewer Context
- The ISBN hard gate is non-negotiable for the importer — no CSV row creates a book without verification; unresolvable rows are reported, not silently dropped (structurally-valid-but-false lesson).
- Bookstore-events: the shared `:scraper_fuse` semantics (proto `scraper.proto:230-239`) apply — event scraping must not melt the price path's fuse; the LLM fallback needs cost caps (Milestone E discipline) and inherits #314's enum-coverage gate.
- Invite-gating changes `register.spec.ts`/`auth.setup` expectations — the E2E fixture path must mint via the test helper, not open registration.
- `min_machines_running = 0` (ROOT H): the events cron only fires while a node runs — the child must state how it actually runs in prod (accepting freshness-only cost, or the read-time/event-driven alternative), not just add a crontab line.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| API/auth | yes | ❌ gate: invited 201 / uninvited generic refusal; importer row outcomes |
| Oban/external | yes | ❌ events job: structured extract on fixture pages; fuse isolation; zero-row sweep 0→N on preview |
| E2E | yes | ❌ invite journey; import journey (fixture CSV); syndication export check |
| Ops | yes | ❌ backup restore drill evidence; prod smoke on real domain |
| Others | n/a epic-level | per child |

Punch: 8 items.
Verdict: baseline ❌ ×8.

## Definition of Done
- [x] Each feature driven live: uninvited registration refused, invited succeeds; a real Goodreads CSV imports with per-row report; a post exports with canonical link; bookstore events render from scraped rows — evidence: screenshots + row counts (see "Wave 11 live drives" note, 2026-08-10: shots 11b-1..4 / 11c-1..3 / 11e-1, report counts 4/0/1/0, feed Atom + owner-token guard)
- [x] Zero-row sweep: `op.bookstore_events` > 0 on preview via the real job (not seed) — evidence: rpc count 0 → batch run → count 1 (the real Wordsworth signing page); job log "2 store(s): 1 event(s) written, 1 with no events page" (2026-08-10)
- [ ] Prod domain serves; backup restore drill completed — evidence: runbook artifacts
- [ ] Feature-Completeness per child ✅ live; validation paths; suites + `just verify` + `just ci`; audit GREEN; `completion-audit`; Completion Bar
- [x] `gdpr-review` on importer + events diffs (new personal data: import provenance; external data classification for events) — cite verdicts: importer **PASS** (11b note), syndication **PASS** (11c note), events **PASS** (11e note)
- [x] `staff-review` per child in Progress Notes — 11a LGTM, 11b LGTM, 11c LGTM WITH NOTES, 11e LGTM WITH NOTES (verdicts above); previously-landed children's verdicts recorded 2026-08-09

## Dependencies
- #320 — the stories these features implement. Reason: spec before build.
- #311 (0d) + #314 (enum gate) — the events job consumes the scrape-outcome contract. Reason: contracts before consumers.
- #317 — invite-gating interacts with resend-confirmation/registration copy. Reason: one registration surface, sequenced edits.

## Agent Assignment
Orchestrator; elixir-agent, elm-agent, scraper/rust agent (events extractor), ops for deploy children.

## Progress Notes
Filed 2026-07-30 by staff-campaign Stage 7. Owner ruling embedded: bookstore-events wired, not deleted.

### 11b — Goodreads CSV import (US-1.1.9) — build complete 2026-08-10
Backend: `Stacks.Imports` (+ `GoodreadsCsv` parser: `="…"` Excel-escape strip, header-addressed columns, unreadable rows kept not dropped), `GoodreadsImportJob` (batch-25 self-enqueue, outcome-per-row idempotent retry, resolver outage retries the batch — NEVER marks unverified — and only fails the import on the exhausted final attempt), `LibraryImportRowRetentionJob` (30-day sweep, 02:30 cron), `ImportController` (202/409/413/422 discriminated), placements gain a `source` provenance column, `place_book/5` carries the reader's Goodreads history (rating, review+notes, binding→format, Date Read→finished_at, Date Added→placed_at). Feed regen coalesced: `placement.created` payload carries optional `source`; PlacementHandler stands down for `goodreads_import` and the job enqueues ONE RegenerateFeedJob per touched bookshelf at finalize.
- Tests: 33 backend (parser/context/job) + controller 9 + handler 2 + GDPR 2 + full suite 3622 green. Elm: Page.Import + Route + Api + poll subscription; ImportTest 9/9, full 1806 green; lint-elm + check-css + lint-proto (all five targets) green.
- Mutation probes (all RED→restored, verified by grep): (1) ISBN gate weakened to shape-only → job test red; (2) PlacementHandler stand-down disabled → handler test red; (3) GDPR delete step skipped → stayed GREEN, revealing the user_id FK CASCADE also erases (double enforcement, recorded in the step comment + test); (4) Elm report filter removed → 3 ImportTest red.
- gdpr-review (importer diff) verdict: **PASS.** New personal data: `library_imports.filename` (dbt_exclude — often carries the reader's name), `library_import_rows.raw_review/raw_notes` (free text). Erasure: explicit `:delete_library_imports` step + user_id CASCADE, rows cascade via import_id — deleted, not author-nulled. Export: `library_imports` key with raw rows while in 30-day retention (portability of the reader's own text). Retention: rows swept at 30 days (data-minimisation; counts survive). Warehouse: rows are `skip_dbt` (no staging model, no sources.yml entry, dbt_grant false); `stg_library_imports` carries counts only, filename excluded. event_log: `library_import.started/completed` carry counts only (PayloadContract-pinned; test proves review text absent). ConsentCheck n/a — importing is the user acting on their own data. Placement `source` is provenance, not PII, accepted_values-pinned in dbt.

### 11c — POSSE/Substack syndication (US-6.2.1 MVP) — build complete 2026-08-10
Honest-mechanism MVP (no fake integration; the platform never holds a Substack credential, sends Substack nothing): public blog Atom feed `GET /api/feeds/u/:handle/blog` (anonymous-ONLY — no `:optional_auth`, its own router scope, declared before the shelf-feed route with a router-ordering test; empty feed = valid 200 Atom so Substack keeps the subscription; ETag + 5-min cache); canonical-tagged export `GET /api/blog/posts/:id/syndication?format=html|markdown` (author-only, public+published-only → 422 `not_public`); syndication records (`op.post_syndications`, canonical URL stored-not-derived) + "Also published at" backlink (http/https-only, rendered `nofollow noopener`); `blog_posts.syndicated` (default true) + `users.syndication_default` + partial feed index (hand migration — generator has no `where:`). Elm: `BLOG_VISIBILITY_PUBLIC` + Public tier in editor; `Components.Syndication` panel on the post page (canonical/feed/export copies via the NEW `copyToClipboard`/`copyResult` port pair — both directions answered so the textarea fallback is reachable; aria-live copy confirmations; not-public posts get the honest sentence with affordances ABSENT, not greyed).
- Tests: syndication context 10 + feed controller 5 (incl. the ⛔ owner-token-changes-nothing guard + route-ordering pin) + SyndicationTest (Elm) 8; suites 3640 backend / 1814 Elm green; lint-elm (incl. ports-wired gate: 21 ports OK, admin-token gate: 7 sites OK) + check-css + credo strict green.
- Mutation probe: feed visibility filter dropped → 2 RED (unit gate + owner-token controller guard); restored, grep-verified.
- gdpr-review (syndication diff) verdict: **PASS.** New columns: `users.syndication_default` (preference — added to GDPR export beside notify_*, satisfies the op.users schema-sweep), `blog_posts.syndicated` (flag), `post_syndications` (ids/target/method/URLs — no free text; UUID-form canonical, no title-derived slug). Erasure: two-hop cascade user→posts→syndications pinned by test (the story's §5 warning). Export: `blog_syndications` key (roster now 14). event_log: `post.syndicated` carries target+method only (PayloadContract-pinned; no title, no body, no URL). Warehouse: `stg_post_syndications` all non-free-text; `int_syndication_reach` DEFERRED with its US-12.x consumer (registry records why post.syndicated is unsubscribed). Third-party disclosure: the panel's closing caption states copies outlive edits/erasure here — disclosure, not a consent gate, since the writer performs the copy themselves.
- Deferred (recorded, not lost): editor post-publish panel embed (panel lives on the post page; editor links there), `post__also-at` top-of-post line, 3-second copy-label reset (confirmation persists until next action), Substack-drafts E2E (cannot be driven — third-party), `int_syndication_reach`.

### 11e — bookstore-events vertical wired (owner ruling: wired, not deleted) — build complete 2026-08-10
The three missing wires, on top of #304/#307/#382's compliant fetch + per-page classifier: (1) **cron** — `DiscoverBookstoreEventsJob` batch, weekly Mon 07:30 UTC (the absent schedule is what kept this pipeline at zero rows); (2) **structured extractor** — `Stacks.Enrichment.EventExtractor` reads schema.org `Event` objects from JSON-LD (@graph/list unwrap, Event subtypes, ISO dates with the never-guess rule) and is believed over the text heuristics in BOTH the listing parser and the per-page path; `.ics` tier deferred (no reachable store links one — #307's enumeration) and LLM tier deferred (no eval framework — the dfef1333 lesson), both recorded in the module doc; (3) **read path** — `Events.listed_events_for_author/1` + public `GET /api/authors/:id/events` + BookDetail fetches on book load and the author card renders real events (dateless events link to the shop's page and are "listed", never "upcoming"; `Nothing`=unfetched keeps the honest "coming soon" stub, distinct from `Just []` "No listed events" — the structurally-valid-but-false-payload rule).
- Tests: extractor 5, parser precedence 2 (+32 existing job tests), controller 3; suites 3651 backend / 1814 Elm green; credo strict + lint-elm green. Mutation probe: structured tier bypassed → precedence test RED; restored, grep-verified.
- gdpr-review (events diff) verdict: **PASS.** No reader data anywhere in the diff: bookstore events are the shops' own public pages (external business data), the new endpoint is public-read of that same data, `enrichment.events_discovered` emission unchanged, no new tables/columns, dbt untouched. The compliance surface is robots/rate-limit (already enforced at the single egress), not GDPR.
- Zero-row sweep + live drive: pending the deploy in flight; the batch job will be triggered on the preview via `core rpc` and `op.bookstore_events` counted before/after.

### Wave 11 live drives + staff-review verdicts (2026-08-10, deploy7 preview)
**Live-drive evidence** (scratchpad `shots/`, deployed preview `stacks-core-pr-feat-campaign-w7-317.fly.dev`):
- **11b import** — full journey driven: chooser → progress ("N of 5 rows") → report **4 shelved / 0 duplicate / 1 unverified / 0 unreadable**, the no-ISBN zine row reported with the gate's own reason; the shelved book verified ON the Library bookshelf (Open Library's title "Nineteen eighty-four" — proof of the live resolver, not a fixture). E2E: goodreads-import.spec 3/3 vs preview. Screenshots 11b-1..4.
- **11c syndication** — panel driven: markdown export → real clipboard carries "*Originally published on [The Stacks]*" + canonical; "Also published at" loop closed and backlink rendered; anonymous feed serves Atom with the post; **owner-token feed fetch identical (platform post absent)**. The drive caught the `syndicated` flag dropped by ProtoJSON's take-list (tickbox unchecked for an in-feed post; toggle response undecodable) — fixed, wire-pinned in proto_json_test, toggle round-trip added to E2E (feed loses the post on untick, verified live). E2E: syndication.spec 4/4. Screenshots 11c-1..3.
- **11e events** — **zero-row sweep: `op.bookstore_events` 0 → 1 via the REAL batch job** run through `core rpc` on the preview: Wordsworth's actual signing page stored (dateless — the page states no date; URL = the shop's own page); Exclusive Books honestly `:sitemap_unreadable` (their sitemap answers HTTP 500 — recorded with timestamp, self-healing via the recheck window). First run recorded a transient "no sitemap declared" for Wordsworth (shop served a challenge/cold answer at 10:06; the same fetch succeeded at 10:10) — the unresolved-reason + recheck design absorbed it exactly as intended. Author read path driven: book detail (The Prague Cemetery) renders "An evening with Umberto Eco — 2026-08-24 — Loot — Details on the shop's page" from `GET /api/authors/:id/events`. Screenshot 11e-1. Batch log: "2 store(s): 1 event(s) written, 1 with no events page".
- Full suites at close: backend 3651 / Elm 1814 / E2E vs preview: setup 3 + import 3 + syndication 4 green; lint-elm, check-css, credo strict, lint-proto (5 targets), admin-token + ports-wired gates all green.

**staff-review verdicts (Mode B, dissenting seat; probes reverted and grep-verified, drives per surface above):**
- 11a invite-only registration — staff-review verdict: **LGTM**. Fail-closed SPA config is the right inversion of the age-gate default; the two live-drive wiring bugs (admin pipeline assigns, mint_session gate) were fixed with pipeline-level tests whose probes red.
- 11b Goodreads import — staff-review verdict: **LGTM**. The gate's vocabulary discipline (unverified ≠ outage; retry-the-batch on fuse-open) is the design's spine and is probe-pinned; the report never hides a row.
- 11c POSSE/Substack — staff-review verdict: **LGTM WITH NOTES**. Notes: (1) the take-list wire bug pattern will recur — any new proto field must be added to ProtoJSON allowlists; consider a completeness guard (follow-up candidate, not filed — ledger); (2) deferred: editor panel embed, `post__also-at` top-line, 3s copy-label reset, `int_syndication_reach` (all recorded in 11c notes).
- 11e bookstore events — staff-review verdict: **LGTM WITH NOTES**. Notes: (1) coverage is structurally capped at 2 reachable stores (the P9 config gap — pre-existing, ledger); (2) `.ics`/LLM tiers deferred with reasons in the module doc; the JSON-LD tier is probe-pinned over the heuristics.

### just ci (integration gate) — first run RED, fixed, re-running (2026-08-10)
First full `just ci` failed three gates — caught only here, exactly per the "just ci is the integration gate" rule:
1. **elixir lint (dialyzer)** — `Accounts.register/2`'s spec omitted the invite-refusal atoms, so dialyzer proved AuthController's whole invite branch dead (guard_fail + 2 unused_fun): an 11a spec defect. Spec widened to the six refusal atoms. Plus my unreachable catch-all in ImportController (removed) and the known Ecto.Multi opaque false positive in Stacks.Imports (`@dialyzer :no_opaque`, matching GDPR.Deletion).
2. **dbt run+test / dbt checkpoint** — `sources.yml` is HAND-maintained (proto.sync does not touch it; the justfile's own step-3 note says so) and was missing `invite_codes` (11a!), `library_imports`, `post_syndications`, plus the new columns on users/blog_posts/placements. All added with PII-exclusion notes mirroring the staging models. dbt: 277/277 PASS; checkpoint: all blocking checks pass; lint-elixir gate exit 0.
Also: the first CI run's completion notification claimed exit 0 because my wrapper's `echo` masked the real status — the log's own `CI_EXIT=1` was the truth. Verdicts are read from the gate lines now, not the wrapper.

### Final just ci (2026-08-10, third run) — 16/16 code gates green; e2e green except pre-existing #397
Run 2 fixes verified: elixir lint (dialyzer) PASS, dbt run+test 277/277 PASS, dbt checkpoint PASS — alongside version-drift, elixir/elm/rust/python tests, proto lint, sql lint, security scans, squawk, licenses (16/16). Deployed-e2e phase: **351 passed**, onboarding overlay fix verified (the Goodreads-import link no longer crowds the overlay's Skip button — `embedded` flag stands it down), evidence drives gated behind DRIVE_EVIDENCE=1. The one red project is `upload` (Modal/vision): 9 failures that are **pre-existing stale expectations against the pre-#351 waiting screen** ("Processing image..." — removed by #351, unexecuted since because chromium testIgnores upload specs) — filed as **#397** with the Together `model_not_available` retirement noted for the same sweep. Observed-flaky for the ledger: `settings.spec.ts:132` writing-assistant consent toggle (passed on retry in run 2, failed in run 3 — timing-sensitive consent write; belongs to #397's sibling sweep or its own follow-up if it recurs).
Completion Bar (box: suites + verify + ci): backend 3651 / Elm 1814 / chromium e2e green; `just ci` cited above with #397 as the named, pre-existing exception. Box 49 (prod domain + backup drill) and the audit/Completion Bar sign-off remain with owner-gated 11d.

### 11d corrected (2026-08-10): the deploy IS merge-triggered — 11d is the launch decision, not a manual deploy
Owner question ("shouldn't prod deploy happen on merge?") prompted a re-read: `deploy-production.yml` deploys on every push to main (SLO gate + auto-rollback), and 13 `main-*` tags prove prod CD has run — #163's bootstrap runbook exists and is only for a FRESH second stack. So 11d's real content is: (1) **the merge of this branch to main** — the launch act itself, owner's call; (2) `INVITE_ONLY_REGISTRATION=true` now set in the workflow env (commit on this branch — without it the merge would have launched OPEN registration, since deploy-stack.sh only self-sets the flag on previews); (3) **#066 backup restore drill**; (4) the beta feedback channel; (5) confirming the prod domain serves post-merge. Items 3–5 are drills/config, not deploys — nothing about them happens "on merge".

### #397 closed IN-WAVE (owner ruling 2026-08-10: "we need to complete 397 before we can complete wave 11")
Final evidence: the full `upload` Playwright project **16/16 green** against a fresh preview with Modal vision (real GPU inference). En route: 8 stale pre-#351 copy assertions fixed; the duplicate-notice spec moved to the completion card (the one-hop manual path's first speakable moment, per #343); the "nonexistent ISBN" fixture replaced after Open Library caught up with the old one (new fixture probe-verified empty in BOTH catalogues); TogetherClient re-pointed at the last surviving serverless Llama (3.3-70B-Instruct-Turbo, live-probed); the zombie-stack failure mode (dead Neon creds reading as total E2E failure) diagnosed. staff-review: LGTM. The Completion Bar's ci citation upgrades accordingly: the previously-named exception is now GREEN.
