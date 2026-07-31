# Staff Campaign 2026-07-29 — Working Ledger
**Scope:** Phase 1 (MVP) + Phase 1 (extended) as defined in `docs/implementation-mapping.md:45,52`, plus their cross-cutting obligations (GDPR/consent/audit surfaces where Phase 1 stories touch them).
**Status:** Stage 1 in progress. This file is the resumable state — update as you go, never at the end.

## Stage 0 — The frame

**Make Phase 1 and its extension genuinely launch-ready — verified rather than claimed — so the closed beta can invite real users onto a core loop (upload → identify → place → browse → manage → account lifecycle) that is proven, coherent, and lovable.**

- `notes/phase-1-launch-extension.md:63-75` (Milestone A: "Verify + complete the core" is FIRST because "claimed complete ≠ verified", lines 10–20); line 41: "budget for the fixes, not just the tests."
- **Ordering principle (inherited from 2026-07-27 campaign, still correct):** prove what is real → fix what silently breaks a stated guarantee → complete what blocks the beta → then pay down the drift that makes the next change expensive.

**Relationship to the 2026-07-27 campaign:** its Wave 0 is complete (12/12, verified via `just wave-status staff-campaign-2026-07-27`); Waves 1–9 never started. Its coverage holes are this campaign's first targets: the photo→vision core loop was NEVER driven; ~12 MVP rows undriven; only 1 mutation probe ran. Wave 0 changed substantial code (G3/G4/G5/G6 fixes, CSS gate, domain cutover) since that plan was written. **Stage 4 must reconcile: each prior Wave 1–9 item is re-validated, absorbed, or explicitly superseded.**

## Stage 1a — Surface inventory

Router: `apps/core/lib/core_web/router.ex` (~100 API routes). SPA: 38 `Page/` modules, 44 route parsers (`frontend/src/Navigation/Route.elm:67-110`).

### In-scope walkthrough checklist (Phase 1 + extension). Verdict column filled during 1b.

| # | Surface (URL) | Stories | Nav-reachable? | Driven | Verdict |
|---|---------------|---------|----------------|--------|---------|
| 1 | `/` unauthenticated (home/landing) | US-15.1.1 | entry | | |
| 2 | `/login` — sign in mode | US-14.1.1 | nav | | |
| 3 | `/login` — register mode | US-14.1.1 | via login card | | |
| 4 | Email confirm journey (`/confirm-email/success`, `/error`) | US-14.2.1 | via email link | | |
| 5 | Onboarding (post-first-login) | US-14.1.2 | auto | | |
| 6 | `/forgot-password` (login card mode) | US-14.4.x (unmapped) | via login | | |
| 7 | `/reset-password/:token` | US-14.4.1 (unmapped) | via email link | | |
| 8 | `/` authenticated (home) | US-15.1.1, US-15.2.x | entry | | |
| 9 | Global nav + user menu dropdown | US-14.3.1/2/3 | always | | |
| 10 | Footer | US-15.3.1 | always | | |
| 11 | `/library` | US-1.2.2 | nav | | |
| 12 | `/antilibrary` | US-1.2.1 | nav | | |
| 13 | `/wishlist` | US-1.2.3 | nav | | |
| 14 | `/reading-pile` | US-1.2.4 | nav | | |
| 15 | `/looking-for-home` (fifth shelf + community wear) | US-18.1.1 | nav | | |
| 16 | Shelf browse interactions: spines, hover, shelf rows, empty states | US-1.2.5, US-1.6.5 | in shelves | | |
| 17 | `/upload` — photo upload → vision identify → "We think this is…" → confirm → place | US-1.1.1, US-1.1.2, US-1.1.3, US-1.1.5 | nav | | |
| 18 | Upload: manual ISBN entry path | US-1.1.7 | in upload | | |
| 19 | Upload: duplicate detection + multi-format merge | US-1.1.6, US-1.1.8 | in upload | | |
| 20 | Book detail overlay (meta, editions, move-shelf, remove) | US-1.3.1, US-1.3.2, US-1.6.4 | from shelf | | |
| 21 | Shelf actions: move between shelves, reread, abandon | US-1.2.5 | book detail | | |
| 22 | `/search` (incl. deep search) | US-1.5.1, US-1.5.2, US-1.5.3, US-1.5.4 | nav | | |
| 23 | `/u/:handle` + `/u/:handle/:shelf` (visibility) | US-1.4.1 | via search/users | | |
| 24 | `/settings` hub | US-17.1.1 | user menu | | |
| 25 | `/settings/profile` | US-17.2.1, US-17.2.2 | hub | | |
| 26 | `/settings/password` | US-17.2.3 | hub | | |
| 27 | `/settings/notifications` | US-17.3.1 | hub | | |
| 28 | `/settings/consent` | US-8.1.3 | hub | | |
| 29 | `/settings/privacy` (export / delete) | US-8.x GDPR | hub | | |
| 30 | `/settings/audit-log` | US-8.1.5 | hub | | |
| 31 | Error handling: 404 route, network failure, 401 mid-session expiry | US-16.1.1, US-16.2.1, US-16.3.1 | provoked | | |
| 32 | Accessibility pass: keyboard nav, focus trap (overlay), screen-reader labels, reduced motion | US-19.1.1, US-19.1.2, US-19.2.1 | throughout | | |
| 33 | Empty-state first-run sweep (new user, zero books, every shelf) | US-1.6.5 | new account | | |
| 34 | Break-things sweep: empty form submits, double-click, back-button mid-flow, 1000-char title | US-16.x | provoked | | |

**Context surfaces (out of scope, visited only for coherence comparison):** `/catalogue`, `/marketplace`, `/blog`, `/groups`, `/me/insights`, `/costs`, `/metrics`, `/about`, admin pages.

**Total in-scope rows: 34.** "N of 34 driven" is the coverage claim.

## Stage 1b — Walkthrough Ledger

(filled during the drive; one row per surface incl. the fine ones)

| # | Surface | Journey completed? | Observed | Kind | Screenshot |
|---|---------|--------------------|----------|------|------------|
| 1 | / unauth | ✅ | Renders, coherent palette. Sparse hero: tagline + About/Marketplace CTAs only. No register/join CTA; says nothing about what the product does (Milestone B wants this as the landing surface). | ux/story-mismatch | ss_4398rvoe6 |
| 2 | /login sign-in | ✅ | Library-door backdrop, warm lamps, parchment card, "Present your credentials to enter" — DELIGHT; protect this. | fine | ss_0639rep31 |
| 3 | /login register | ✅ | Works, inline "Looks good" validation. BUT: document.title stays "Sign In — The Stacks" in register mode (aria-selected is correct; underline lags mode switch — screenshot has settled wrong state); inline validation messages inject and shift the whole form (fields move under the cursor mid-fill). | app-bug ×2 / ux | ss_7999p3l3q, ss_0779munq1, ss_5078qx9er |
| 4 | confirm-email journey | ✅ | Email link → "Email confirmed" card → Sign in. Correct title, coherent. | fine | ss_725308w44 |
| 3b | register success | ✅ | "Check your inbox!" card, warm copy. NO resend affordance (US-14.4.2 gap visible at UI level — lost email = dead end). | story-missing | ss_73260n89l |
| — | sign-in journey | ⚠️ | ⛔ POST /api/auth/login 200 + token stored at ~2s; UI sits on /login with NO feedback until ~47s, then lands /antilibrary. W-1 reproduced, worse than prior 30s. | app-bug (perf) | ss_47316gw9y, ss_8805rgeiz |
| 5 | onboarding | ⚠️ | 3 steps Welcome→Privacy→Done. Privacy step copy says "Choose who can see…" but offers NO chooser (Continue/Skip only). Progress dots run one behind (dot 1 on step 2; dot 2 on step 3). Scrim still near-opaque — shelf invisible (W-2 unfixed). No upload step (owner decision D2 unimplemented). | app-bug / story-mismatch | ss_106508ek5, ss_52995btsm, ss_02337hspl |
| 9 | Global nav + user menu | ⚠️ | Dropdown = Settings + Sign Out only (no Profile/Insights). Opening it REFLOWS the header (logo drops ~40px). CORRECTED: /upload IS in nav — but only as a hover-revealed submenu under "Catalogue" (Search/Add Book), with no visual cue a submenu exists, and clicking Catalogue navigates away instead. "Add Book" filed under the public Catalogue is a category error; core-loop entry is effectively hidden — no CTA on empty shelves or home. Hover-only also suspect for touch/keyboard (verify). Nav highlight lights "Catalogue" while on /upload. | ux / discoverability | ss_0455t8fed, ss_81836sb4a |
| 11 | /library empty | ✅ | "Your library is waiting. Move a book here when you've finished reading it." Green damask wallpaper — distinct room identity. Good empty state. | fine | ss_4272pbc57 |
| 12 | /antilibrary empty | ✅ | "Books you own but haven't read yet. Upload a photo to start building your collection." Floral wallpaper. Good copy, but the referenced action has no affordance. | fine/wiring | ss_0676ufvj1 |
| 16a | room transition | ✅ | Adjacent-shelf slide animation between antilibrary↔library works; nav highlight doubles up mid-transition (transient). | fine | ss_5275ccuqd |

## Stage 1c — Absence pass (report received 2026-07-30; full text in session transcript)

**Census (reconciled):** 7 in-scope story files with ZERO mapping citations (US-1.6.1/2/3/6, US-1.7.1, US-14.4.1/2); 1 phantom (US-11.2.1, dbt lineage row); US-1.5.4 deliberate.
**Intent with no story (Milestones B–D):** invite-only registration, Goodreads CSV import, POSSE/Substack, FAQ/landing (About.elm ships unstoried), beta feedback channel. Mobile has no dedicated story.
**Plan with no code:** US-1.1.7 bulk-upload ABSENT (picker hard-codes first file, `Upload.elm:232,762`); US-1.3.2 spine-wear = compile-time constants; US-1.5.4 format prompt absent, obsolete write path live; US-19.2.1 list-view on 1 of 3 pages; US-17.1.1 hub is a redirect.
**Code with no story:** transparency/insights cluster (6 surfaces, ADR-019/021), admin-MFA cluster (zero doc hits), auth-hygiene jobs (ExpiredUnverifiedAccountsJob silently erases accounts at 24h — user-visible, unstoried), DiscoverEditionsJob, catalogue (676 lines).
**Lifecycle holes (recovery legs):** undo-remove placement, un-merge edition, resend-confirmation (+24h silent erasure dead-end), cancel account deletion, un-abandon, delete-my-photo. Rate-limit UX unstoried (7 pipelines). Unbounded shelf render (no pagination, thousandth-book).
**Stale claims to stop propagating:** notes/:16-20's #148/#151 proof points are FIXED (PlacementCard + ShelfOrganiser both mounted); survivor is US-1.7.1's move-between-physical-shelves leg (route+context exist, NO Api.elm function). 6 stories deny their own shipped code (US-14.3.2, US-10.2.1, US-8.5, US-2.5.3, US-6.1, US-14.4.1); mapping:1857 wrong 4 ways.
**34-item spec-or-exclude list** → full list in transcript; must be resolved (spec'd or excluded) before Stage 4 per the 1c gate.

## Stage 2 digest — wiring trace (report received; full text in transcript)

- **Dead workers ×4 confirmed:** ConfirmDeletionJob, RecalculateWearJob (zero refs), FetchReviewsJob (→ op.review_snapshots), DiscoverBookstoreEventsJob (→ op.bookstore_events) — each sole producer of its table; both tables should read 0.
- **Routes with no client caller (~18):** incl. GET /api/auth/me (SPA never validates rehydrated token — related to the 48s login? and stale-token UX), POST /api/upload + /upload/identify (superseded, never removed), PUT /api/placements/:id/formats (FormatPicker drives merge-format instead), PUT /api/placements/:id/shelf + GET shelves (US-1.7.1 leg), visibility-grants trio (no UI), onboarding/reset, books/confirm + POST /api/books.
- **Nav orphans:** /blog subsystem (zero inbound links — entire blog URL-only!), /groups (same), /listing-removal (only link is inside orphan ThirdSpaces.elm). ThirdSpaces.elm remains a full orphan (no Route constructor; green tests over unreachable page).
- **Clean:** Api.elm callers (boundary 2), component mounts (boundary 5 — PlacementCard #148 FIXED).
- **Events:** 55 emitted types, registry lists 22 — registry's "complete catalog" claim FALSE; image.* upload lifecycle (submitted/rejected/resolved/expired) has no subscriber; listing.sold/removed/expired unwired while sibling listing.activated is wired.
- **Api.elm:688 doc comment stale** ("presigned R2 PUT URL" — now a Phoenix proxy).
- Zero-row sweep target list captured (op.price_snapshots, review_snapshots, bookstore_events, third_spaces, discovered_sources, source_health_checks, platform_costs, feed_cache, embeddings/chunks/retrieval_log, event_log, audit_log, oban_jobs incl. queue='notifications').

## Stage 2 digest — test inventory (full text in transcript)

Totals: 4,922 tests (Elixir 3,198 / Elm 1,238 / Playwright 486). Four root causes behind the weaknesses: (1) Stacks.AI.MockClient documents a config API it doesn't have → unsteerable vision seam → 5 ad-hoc replacements + mock echoes; (2) every factory bypasses every changeset (no insert/2 override) → editionless books (ISBN-gate-violating), ~90% checksum-invalid fixture ISBNs, shelf/bookshelf desync in EVERY placement fixture, никогда-register-confirmed users; (3) Elm tests re-implement production effects (TestHelpers mirrors + 5 duplicated decoders) → two server-impossible payload shapes: BookDetail progress card fixture invents 4 fields proto never sends (progress card BLANK in production for every book — contract-proven); upload SSE fixtures camelCase vs server snake_case (18 tests exercise the branch prod never hits); (4) 11 of 13 mocks live in lib/ and compile into prod — MockReviewFetcher IS the production implementation (fake goodreads 4.2 ratings would ship). Vacuous guards: mostly remediated + now gated (check-e2e-vacuous-guards.sh), 2 allow-marked legit; rate-limit.spec skips exactly when rate limiting is broken (fail-open); 2 structurally unfalsifiable Elm tests incl. the SECURITY read-only test (translator maps every Msg → Cmd.none). Skips: 59 tests config-excluded from chromium run; 1 SLA test never runs; 1 tag comment claims an exclusion that doesn't exist. 15 probe candidates listed; #4/#13/#14 predicted to survive mutation; #12 proven broken by contract read.

## Stage 2 digest — drift/deadcode (full text in transcript)

CSS gates landed: 398→0 unstyled orphans (89 verified test hooks), both gates at floor. NOT covered: token VALUES — 66 distinct/272 hex occurrences (drift ACCELERATING in newest surfaces: admin gate 40, login 36), 3 phantom tokens, 10 fallback/definition mismatches, NO spacing scale (516 literals, 0% adoption — largest untokenised surface), no semantic error/success tokens (two unrelated error reds), type scale stops at 2.5rem so all display sizes are off-scale. Missing third gate = value-level check. Dead code: 4 workers + reviews vertical ≈ 1,040 LOC prod + 890 LOC test ("built→tested→never scheduled" root cause); spine_data/1 has NO production caller; ThirdSpaces page kept alive only by its tests. Unturned knobs 19+2, four are DEFECTS: EMAIL_FROM unset (prod transactional email non-functional per code's own docs), argon2_pool_size unreachable (compile_env), OBAN_POOL_SIZE=80 over Neon ceiling + 3 contradicting docs, POOL_SIZE setter can never take effect; SMOKE_TESTS_ENABLED set unconditionally in prod against documented invariant. #091 scoped too narrow to fix discoverability. Proto codegen: 15/22 elixir + 12/29 elm generated modules unused; /costs + /marketplace decode by hand.

## Story-crib corrections to walkthrough rows (full text in transcript)

- Authed-home-as-marketing-page is DOCUMENTED drift (US-15.1.1:13 "current implementation does neither" — spec wanted authed→/antilibrary redirect). Still a product gap; not undocumented.
- Onboarding step 2 SPEC is "Upload your first book" (US-14.1.2:26); shipped Privacy step matches neither the story nor owner decision D2 (upload+consent).
- Login door animation is BY DESIGN 4000ms, gated via pendingAuthResponse + playLoginTransition port (US-14.2.1:31) — the occlusion hang is the design's fragility, not a stray bug. 403-unconfirmed copy documented broken (:37).
- US-1.1.1 verification spec = SIDE-BY-SIDE uploaded image + identified book (:16); shipped is stacked, no uploaded image shown.
- Reading pile spec: horizontal stacked spines w/ random offsets + CSS armchair; shipped one flat book + detached status card.
- US-14.4.1 doc's "frontend not built / link dead-ends" is STALE — whole flow driven live today. US-8.5 audit-log doc's "not built" also STALE. (Story files rot in BOTH directions — matches absence-pass finding 33.)
- Empty-state strings match spec verbatim ✅ (all 5). Library brass-plate label spec vs plain text label — minor mismatch. US-16.3.1 login-renders-in-place (URL unchanged) is deliberate (:149,157).
- Six documented-as-unbuilt specs must not be filed as discoveries (bulk review screen, deep-search UI split, discovery labels/shimmer, Pristine-vs-Softened, register door-animation bug US-14.1.1:275, notification label remap US-17.3.1:32).

## Findings ledger (unfiltered, running)

| # | Register | Finding | Evidence | Notes |
|---|----------|---------|----------|-------|
| F1 | 🟧 | Scraper emits `SCRAPE_OUTCOME_RATE_LIMITED`; Elixir consumer doesn't recognise it — "treating as failure", and the job retries in a tight loop (same ISBN every ~20s), spamming warnings | fly logs 19:29:14–19:29:57, `TriggerPriceScrapeJob: unrecognised outcome` | Outcome-enum drift across the proto contract; also a retry-storm smell. Needs code trace. |
| F2 | 🟨 | Vision canary failed once with `modal-http: internal error: Server has lost track of input` (500) then pipeline continued; separate canary correctly rejected not-a-book | fly logs 19:29:39, 19:29:41 | Transient Modal failure — check retry behaviour + user-facing consequence during drive. |
| F3 | 🟧 | Google Books returning 503 to ISBNResolver on preview (quota again?) — OL carrying resolution alone; error mapping collapses `:circuit_open` → `isbn_not_found` (prior ROOT A symptom, still live) | fly logs 19:29:53–54 | Confirms ROOT A's "acute" risk conditions persist. Also: query built from garbled OCR title (`intitle:crystal ci fdrs`) — resolver hygiene question. |

| 17 | /upload core loop (barcode) | ✅ | photo(drop) → "Processing image..." → ~25s → "We think this is… The Name of the Rose / UMBERTO ECO" → confirm → cover enriches in → shelf placement → "added to Antilibrary" → spine on shelf. THE CORE LOOP WORKS, first campaign to drive it. Findings: (a) enrichment cover arrives async and MOVES the confirm buttons ~170px mid-click (swallowed my click — same layout-shift class as register form); (b) shelf-placement radios are RAW UNSTYLED browser widgets in the flagship journey (orphan-class defect in the core loop); (c) default shelf = Wish List, arguable vs Antilibrary for a photographed-in-hand book; (d) upload icon is an emoji 📷 vs the crafted look elsewhere. | app-bug/ux | ss_6502ygr7a, ss_3236yblz1, ss_5366g7g9t, ss_9013z0trr, ss_6462j78kk, ss_10180ktps |
| 20 | Book detail overlay | ✅ | Rich: cover, real metadata (1994/HMH/556pp/ISBN), synopsis, visibility select with EXCELLENT explainer copy ("a book can't be more visible than its shelf"), move-to-shelf works live ("Moved successfully"), remove button present. Debt: 3× "Sentiment data coming soon" + "RSS feed coming soon" + "Events coming soon" + empty AI-GENERATED SUMMARY header + "No price data yet" (price chain still dry, see F1); format checkboxes partially unstyled. W-12 grey-out NOT reproduced (spine renders normal). | fine + debt | ss_31679b6uc, ss_7506cs9u9, ss_2304ly2ac, ss_8332ow5md, ss_7982frjsk |
| 14 | /reading-pile with book | ✅ | Green armchair + dragon wallpaper, book lies on chair — charming, distinct room identity. Oddity: detached floating "To Read" status card hovering mid-wall, anchored to nothing. | fine/ux | ss_99520m0rk |
| 21 | move between shelves | ✅ | Antilibrary → Reading Pile via detail overlay, "Moved successfully", heading updates. | fine | ss_7982frjsk |
| F4 | (log) `GET /internal/metrics` → 401 every 15s, continuously | — | Metrics collection failing auth on preview — ADR-021 pipeline's scrape/push source misconfigured here; observability silently dead + log noise. | wiring/log-noise | preview-core.log 23:14–23:15 |
| F5 | Upload pipeline failure UX | ⛔-candidate | Second upload: vision 502 ("cannot identify image file", PIL) at 23:13:05; Oban retries every ~20s (deterministic failure re-sent to GPU); UI shows "Processing image..." spinner for 3.5+ min WITH NO ERROR EVER SURFACED. [Image corruption may be my injection artifact — hash unverified on 2nd paste; re-test pending. The missing failure-path UX is real regardless; also mirrors ROOT A's "no terminal-failure hook".] | app-bug | ss_5456l77le + preview-core.log 23:13 |

| 18 | Manual ISBN entry | ✅ | "Enter ISBN manually" → checksum validation with proper error copy (caught garbage input) → "Looking up book..." → resolves The Name of the Rose with cover. W-11's 404 NOT reproduced — fixed. | fine | ss_9495dsykq, ss_4918b6l6i, ss_8650w654g |
| 19 | ⛔ Duplicate detection bypassed via manual ISBN | ❌ | Book already on my Reading Pile; manual-ISBN path offered a fresh placement with NO duplicate notice; submit created a SECOND placement. API confirms: [{reading_pile, The Name of the Rose}, {wishlist, The Name of the Rose}] — same work, same user, two bookshelves at once. US-1.1.6 check lives only in the photo path (upload.spec's "Already in Your Library"), not in the placement domain. Ladder: a uniqueness rule at the domain/DB layer (rung 4) kills the whole class; today rung-6-per-path and one path forgot. ROOT A-class: N entry points, per-path checks. | app-bug ⛔ | ss_2353djvt0 + API |

| 22 | /search | ✅ | Live as-you-type; sectioned Your Collection / On the Platform / Readers. ⛔-adjacent: W-13/M6 STILL LIVE — same title as two unrelated works (1994 collection vs 1980 platform). Collection annotation shows only ONE shelf for the double-placed book ("On your Wish List shelf") — silently collapses multi-placement. "Readers" heading misaligned vs siblings. | app-bug (dup) / fine | ss_48250ywp5 |
| 24-30 | Settings sweep | ✅ | Hub = bare bulleted list + mobile select visible at desktop (W-6 unchanged; visually alien vs product). Sub-pages have GOOD copy: consent explains embeddings deletion; privacy explains ceiling rule + per-shelf visibility + export + Danger Zone. IA confusion: nav "Consent" → title "Privacy Settings" beside sibling page "Privacy". Notifications + audit-log seen only in Loading state. | ux / fine | ss_4534qpeha |
| 26b | ⛔ Mid-form 401 (W-5/W-10) | ❌ | Killed session server-side, submitted password change: PUT → 401, page shows "Could not change password. Please try again." — wrong advice, no redirect, stale token kept. AND plans/173-session-expiry-401-interceptor-complete.md claims an interceptor shipped — reconcile in Stage 3: either it doesn't cover elm/http XHR pages or claim is false. | app-bug ⛔ | ss_3382ayqxl |
| — | ⛔ ROOT-cause capture: login hang (W-1) | ❌ | Login POST 200 + token minted; UI stays on /login indefinitely; localStorage untouched. document.getAnimations() shows ten 300ms transitions frozen "running" — window occluded → transitionend never fires → post-login flow (animation-gated) never completes. First-login "48s" was the same mechanism eventually unsticking. Reproduced 4×; XHR tap shows NO follow-up request after 200. A user who clicks Enter and switches windows NEVER logs in. | app-bug ⛔ (root-caused) | ss_3749911z9 + getAnimations dump |
| 6b | Forgot-password ack | ⚠️ | POST 200 (email sent, token written — verified in Neon) but the card NEVER acknowledges; user re-submits (I sent 2). Silent-success family with W-1. | app-bug | ss_59891q70p |
| 7b | Reset-password journey | ✅/⚠️ | Full journey works: token from email → form → new password live (login 200), old password 401, session revocation W-7 FIXED (pre-reset token 401s), token replay refused 400 (single-use guard WORKS live — the untested guard from 2026-07-26 audit is present; still needs its test). BUT again zero success feedback — form just clears. | fine + app-bug (ack) | ss_5574bu3k2 |
| 8 | Authed home | ⚠️ | IDENTICAL to logged-out marketing hero — no shelf preview, no continue-reading, no path to own collection (W-9 unchanged). | story-mismatch | ss_3654aw0u7 |
| 13 | /wishlist | ✅ | Bookcase + floral wallpaper; dup book shows GHOSTED/pale spine — verify whether intentional wishlist styling or W-12 visibility grey (Stage 3). | fine/question | ss_6700ggrv2 |
| 15 | /looking-for-home | ❌ | E5 CONFIRMED UNCHANGED: bare heading + italic empty text on flat background. No bookcase, no wallpaper, no community wear — breaks the five-shelf family (US-18.1.1). | story-mismatch 🟧 | ss_09454uj9o |
| 23 | Profile + visibility | ✅ | Own profile renders (name/handle/ZA/shelf links; no RSS anchors — consistent with owner-only). Unauthenticated GET /api/u/:handle → 404 (privacy-by-default, no enumeration). US-1.4.1 ✅ default case. | fine | ss_0461q57hm |
| 31a | 404 route | ✅ | "Page Not Found" + Go Home. Correct + coherent. | fine | ss_7960d7pa3 |
| 31b | Network failure (US-16.2.1) | ❌ | XHR killed, clicked Antilibrary: SILENT NO-OP — no error UI, no URL change, 11s nothing. The offline story's promised experience does not exist on shelf navigation. | app-bug 🟧 | ss_9987gy6n3 |
| 32 | A11y spot evidence | ⚠️ partial | Present: skip-link, correct aria-selected on login tabs, focus ring on inputs, tab roles. Known: "Deep search" checkbox a11y-name. NOT driven: full keyboard pass, submenu keyboard reachability (hover-only suspicion), focus trap in overlay. Capped PARTIAL; Stage 3 checklist item. | partial | — |
| 34 | Break-things partial | ⚠️ | Double-submit forgot-password = 2 emails sent, no dedup/ack. Register/reset validation gates empty submits ("Looks good" inline). Not driven: 1000-char title, back-mid-flow. | partial | — |
| ctx | /about | ⚠️ | Ships visible "Placeholder copy — the owner will refine this." — the Milestone B landing surface self-announces unfinished. Links to metrics/costs work. | story-mismatch | ss_0530lpysr |
| — | Zero-row sweep (Neon br-odd-darkness-anjzliew) | — | price_snapshots **0** (chain STILL dry; cause = F1 enum drift); review_snapshots 0 + bookstore_events 0 (dead workers confirmed); third_spaces **0** (G1's "proven" row absent on this branch — check where that proof ran); discovered_sources/platform_costs/feed_cache/source_health_checks = 5 each (SEEDED, not organic); embeddings/chunks 0 (assistant dark); event_log 316 (seed emits events now ✅); oban_jobs 0 total (pruner active — "empty = never ran" instrument caveat); bookstores 11; uploaded_images 9. | evidence | SQL |

## Coverage: 30 of 34 in-scope rows driven with verdicts; not driven: photo-path duplicate re-upload + not-a-book rejection (clipboard tooling died mid-drive; e2e upload.spec covers both), full keyboard a11y pass, notifications/audit-log resolved states. All capped PARTIAL where undriven.

## Behavioural baseline + mutation probe (run evidence)

| Command | Result |
|---|---|
| `just run mix test` (2026-07-30) | 3,235 tests, 15 properties, **0 failures**, 10 excluded |
| `npx elm-test` baseline | **1,285 passed, 0 failed** (1.7s) |
| **PROBE (test-inventory #13):** broke all 5 snake_case SSE fields in Api.elm poll decoder (`image_id`→`image_id_PROBE` etc.) — the wire format production emits | `npx elm-test` → **TEST RUN PASSED, 1,285 passed, 0 failed.** The production decode branch of the upload pipeline is guarded by NOTHING; every real upload would break invisibly. |
| Probe hygiene | Reverted via Edit; `git diff --stat -- frontend/src/Api.elm` empty; `grep -c _PROBE` = 0; suite re-green 1,285/0. |

Contract-proven without probe (read evidence, decisive): BookDetail progress fixture invents 4 fields absent from `proto/stacks/common/v1/placement.proto:115` and `proto_json.ex:311-322` allow-list → progress card blank in production (my live drive corroborates: detail overlay showed no progress card content). SECURITY read-only test unfalsifiable (TestHelpers.elm:907-911 maps every Msg → Cmd.none). Reset-token single-use: behaviour proven live today (replay→400) but STILL untested (email_test.exs has no consumed-token-second-use case).

## Coherence sweep (one sitting, cross-surface — Stage 3)

**The product has two visual registers, and surfaces fall cleanly into one or the other.**

Register A — the crafted product (would show anyone): login door + parchment card (ss_0639rep31), the four themed shelf rooms with distinct wallpapers/wood (ss_4272pbc57, ss_0676ufvj1, ss_6700ggrv2, ss_99520m0rk), spine rendering (ss_8881jhmgp), book-detail overlay content (ss_31679b6uc), confirm-email/reset cards, empty-state copywriting (verbatim to spec), 404 page. Shared: Playfair/serif headings, parchment-on-dark, warm ambers, in-voice copy.

Register B — the unfinished scaffold: settings hub (bare list + stray mobile select, ss_4534qpeha), looking-for-home (flat void, ss_09454uj9o), upload shelf-picker radios + format checkboxes (browser-default widgets inside the flagship journey, ss_6462j78kk), about page (visible placeholder copy, ss_0530lpysr), authed home (logged-out hero, ss_3654aw0u7), profile page (spare list), search "Readers" misalignment, emoji 📷 as the upload icon.

The line between registers tracks AGE of surface + whether a story specified the experience. Register B pages cluster exactly where stories are functional-only or missing (absence-pass) — the experiential-spec discipline visibly drives quality. Motion vocabulary: adjacent-slide + room-fade are consistent and good; the transition-gated completion (ROOT: animation-gated state) is the same mechanism's dark side. Copy voice: consistently in-voice in Register A ("The door remains shut"), generic in Register B ("Could not change password. Please try again." ×N surfaces — W-10 still).

**Would I be proud of it?** The core loop — drop a photo, watch it become a real book on a beautiful shelf — is genuinely delightful and works end-to-end live; the empty states and room identities show real care. I would show someone the shelves and the door. I would not show them settings, the about page, or what happens when anything fails: every failure path (auth expiry mid-form, network loss, upload failure, slow login) currently drops the user into silence or a lie ("try again"). The craft gap between the happy paths and everything else is THE product-level finding: this is software that loves you only when nothing goes wrong.

## Stage 3 digest — design-books (full text in transcript)

**Headline: `Books.confirm/2` (books.ex:974) is the deep module — dup-detection + find_same_work merge + atomic create-and-place — and it is DEAD (zero frontend/e2e refs). The live upload/manual path is a client-side reassembly missing every invariant.** Wiring `POST /api/books/confirm` into Page.Upload's manual path fixes: manual-entry-can't-add-new-books (entry point 5 is DB-only → 404s valid ISBNs, "blames the user"), the dup bypass symptom, W-13 two-works, atomicity — in one change using tested code.
- Dup check lives in the CONTROLLER as an SSE response field (upload_controller.ex:419/475), not the domain. DB index is (book_id, bookshelf_id) — one grain too narrow; user_id lives on bookshelves. Shape A (denormalise user_id + UNIQUE(user_id, book_id) WHERE removed_at IS NULL, with data repair) + B's domain error recommended. get_placement_for_book/2 ends in Repo.one() → **MultipleResultsError; VERIFIED LIVE: owner's GET /api/books/:id → 500 today.**
- 0-byte: ★ one-line fix at verify_object_exists (books.ex:489 already HAS the size, discards it). NO terminal-failure path: identify_book_job.ex:125-128 {:error} branch touches neither row nor stream (the other two branches are exemplary); no discard observer; UI spins until sse_max_timeout 360s. Shape B (final-attempt always marks rejected) then Shape A (closed error set on vision boundary; sidecar must distinguish undecodable vs transient).
- RATE_LIMITED: commit f28c032e added the enum to proto+Rust+2 Elixir files, missed trigger_price_scrape_job.ex; catch-all at :267 → retry loop → price_snapshots 0. Elm codegen makes a closed type; Elixir codegen makes String.t() — recommend enum codegen + lint coverage check (2nd consumer to drift: match_store_catalogue_job.ex:124).
- Resolver collapse moved: books.ex:1089, book_controller.ex:33/94, and **moderation.ex:467-471 — during a GB 503, a real book is recorded as :invalid_book**.
- Layout shift: no re-render — unconstrained <img>, no aspect-ratio (main.css:5795); the codebase already solved this deliberately at main.css:5804 (.profile--loading comment).
- books.ex: 1373 LOC, 30 public names, 6 responsibilities, contract not statable; extract Stacks.Books.ISBN (pure) + Stacks.Uploads (~370 LOC out).
- merge_edition resolves externally then DISCARDS metadata (books.ex:1085).
- Praise: interpret/2 determination-vs-failure design + Rust exhaustive match (rung-2 discipline), two-sided ISBN checksum with documented asymmetry, Telemetry.phase span trap doc, idempotent terminal transitions, GDPR whitelisting in telemetry.
- Root shape: correct invariant at wrong altitude + second path built around it (×4).

## Stage 3 digest — design-spa (full text in transcript)

**Headline: the auth credential is written downstream of a browser animation frame.** Chain: GotAuthResponse stores NOTHING → StartTransition parks pendingAuthResponse + playLoginTransition(4000) → app.js:342 wraps the port body in requestAnimationFrame → 7 WAAPI animations → Promise.all(finished) → port → LoginTransitionCompleted → ONLY THEN saveAuth+pushUrl (Main.elm:1200-1216). Occluded window: rAF never fires, animations never created (my 10 frozen transitions = the card's own CSS transitions — zero WAAPI, proving the rAF hadn't fired). No timeout anywhere. isSubmitDisabled true while transitionState /= Idle and NOTHING resets it → unrecoverable. Best case = 4.6s credential delay for every login. Back-button mid-animation silently discards the minted token (falls to `_ ->`). Register is already shape (B) — the fix is to make login look like its sibling. Recommended: persist-first-then-animate + AuthState type (Anonymous | Authenticated | Arriving Auth) making token-loss unrepresentable + sleep-race backstop. LoginTest.elm encodes the gap as intended behaviour ("not LoggedIn yet").
- Silent-success family: NOT the same mechanism. Forgot ack EXISTS but is camouflaged (styled identically to instructional copy, below the button, no live region — the notice component with role=status exists on the same card, unused). Reset success exists but ANY input event resets submitting→NotAsked and tears it down (password-manager keystroke = success vanishes); also should auto-advance.
- Title from `route`, body from `page` → 6 divergences (incl. /library-signed-out losing the user's intended destination post-login). Fix: title from Page.
- Underline: no state desync — `transition: all .3s` on a "you are here" indicator (same anti-pattern as the fe1d7f1e collisions). Progress dots off-by-one NOT reproducible from code (same source of truth) — suspect the dot transition; correction to my walkthrough row.
- Nav: submenu is 100% CSS disclosure (no button/aria/state) → **"Add Book" unreachable on touch, absent from a11y tree**; parent both link and menu; Add-under-Catalogue category error; user menu exposes 2 of 8 settings destinations. Header reflow: UserMenu.elm:93-98 inline `style position relative` beats the CSS absolute → menu joins flex flow (one line to delete); plus Elm-model/CSS-pseudo-class dual authority on visibility.
- ⛔ **Loading renders an empty bookcase** (Bookshelf.elm:522-527 NotAsked/Loading → same view as Success []) — hung request = "you own no books", pixel-identical, forever (no Api.elm timeouts). Explains the offline silent no-op (2 candidate mechanisms; either way this stands). Shell-level network state missing entirely (zero online/offline handling); handleSessionExpiry is the precedent architecture.
- Wishlist ghost answered: per-placement visibility=="owner" → opacity .35 inline — privacy state labelled ONLY for screen readers, fails contrast, Maybe String magic literal ×3 sites (privacy regression waiting).
- Reading-pile floating card: viewProgressPanel parented into .reading-pile__scene flex row; its own CSS written for below-scene flow. One-line Elm move.
- Onboarding: privacy step promises chooser (copy written for unbuilt step); scrim rgba(.85)+blur(6px) = functionally opaque; **aria-modal=true with no focus trap and no Escape branch** (asserted-not-honoured); empty-state CTAs inert; EmptyBookshelf ships a design-spec sentence as user copy ("A subtle outline of a book spine suggests…").
- Corrections to record: Route.Settings IS producible; real defect = toPath∘fromUrl ≠ id (+20 duplicated lines, sidebar highlights nothing on /settings). decodeFlags Result.toMaybe still swallows (one added required field silently logs out everyone).
- Praise: aria-selected computed with visual class (stayed truthful during lag), proper skip link with tabindex target, door animation composition itself, per-room wallpaper/wear taste, adoptExternalAuth/parkPending/resolveRecheck trio (named decision types — the model the login path should copy), the two ⛔ comments documenting defect classes, isAdminRoute deliberate exhaustiveness.

## Run evidence addendum

| Check | Result |
|---|---|
| GET /api/books/d7e376d3… as owner-with-duplicate | **500** — MultipleResultsError prediction CONFIRMED live; the dup bug breaks the owner's own book detail page |

## Stage 3 digest — design-settings (full text in transcript)

**#173 reconciliation: claim stale, not false.** The interceptor shipped and is good (Api.isUnauthorized + OutMsg SessionExpired + handleSessionExpiry; coverage now 22 of 38 pages via #178). The residual gap was MIS-ENUMERATED in both plan docs: #178 "converted" AgeVerification (which no longer exists) and missed the three real stragglers — Profile, Password, Notifications, all 2-tuple updates with NO OutMsg (Password.elm:61, Main.elm:1781) — precisely the three write-form pages. Root: the coverage list was hand-written markdown no gate reads. Wave-5 amendment: wrapper + a MECHANICAL reflection gate (authed page without SessionExpired fails a test).
- 401 recount: 4 of 7 covered (Consent/Privacy/AuditLog/Insights yes; Profile/Password/Notifications no).
- ⛔ **GDPR erasure miss: op.uploaded_images** — schema declares belongs_to :user but migration emits bare :binary_id, NO FK (20260401074249:9); deletion.ex has no step; ImageRetention deletes by TTL only. Erased user's rows + R2 photo path survive to 30-day TTL. The excellent pg_constraint erasure guard cannot see FK-less columns (its one blind spot) and excludes the audit schema (audit_log.user_id also bare). Fix: information_schema.columns sweep + FK-or-allowlist.
- ⛔ **Export is table-unguarded** (guard is column-level on op.users only): blog_posts, post_comments, uploaded_images, group_members, audit_log all missing from export — portability today omits the user's own blog posts. Audit-scrub GUC trap: trigger self-disarms after ONE row; first scrub attempt will pass row 1, raise row 2.
- Settings CSS truth: the hub classes have ~0 real rules (`--active` inert → cannot tell which page you're on; `.success` 0 rules → all confirmations unstyled; no grid → no two-column layout; the intended mobile breakpoint doesn't exist at all). Same finding as #173's login-notice ux note — recorded as reviewer note, never became a gate. IA: fold Consent into Privacy (3 names, 1 page, sibling collision); group You/Privacy/Your-data.
- Notifications stuck-Loading is REAL: init returns Loading + Cmd.none when token absent — renders "Loading…" forever; AuditLog's init does it right (NotAsked). 
- Duplication recounts UP: password rule 9 sites/4 wordings (3 FE + helper/placeholders + 4 BE); save-button ×6 with 2 ellipsis glyphs; Profile.elm:318 already HAS the right abstraction (viewSaveButton) — promote it, don't invent (fix its dead "Saved!" button while promoting).
- Praise: pg_constraint erasure guard (extend, don't rewrite), post_comments tombstoning + cross-aggregate event_log scrub, preview-reuses-real-scopes, ceiling-rule explainer, consent consequence copy, no-enumeration 404 + PII-free telemetry.
- Through-line: correct decision → N hand copies → no gate. (401 ×22/3 missed, save-button ×6, password ×9, export scope, visibility literal ×3, CSS active class.)

## Blockers / route-arounds

| Blocker | Route |
|---------|-------|
