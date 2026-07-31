# Staff Engineer Campaign — Remediation Plan
**Date:** 2026-07-30 · **Scope:** Phase 1 (MVP) + Phase 1 (extended), `docs/implementation-mapping.md:45,52`
**Working ledger (full walkthrough rows, digests, screenshots):** `plans/staff-campaign-2026-07-29-ledger.md`
**Supersedes:** the unstarted Waves 1–9 of `plans/staff-campaign-2026-07-27.md` (its Wave 0 is complete and verified; every surviving item from its Waves 1–9 is absorbed below with corrections — nothing from it should be executed as written there).

## The frame

**Make Phase 1 and its extension genuinely launch-ready — verified rather than claimed — so the closed beta can invite real users onto a core loop that is proven, coherent, and lovable.**
`notes/phase-1-launch-extension.md:63-75` (Milestone A "Verify + complete the core" is first because "claimed complete ≠ verified"; line 41: "budget for the fixes, not just the tests").

**Ordering principle:** prove what is real → fix what silently breaks a stated guarantee → complete what blocks the beta → then pay down the drift that makes the next change expensive.

## Coverage

| Area | Surveyed | Driven live | Tests probed |
|---|---|---|---|
| All Phase 1 + extended surfaces (34-row inventory) | ✅ | **30 of 34** | 1 run-probe + 3 contract-proven |
| Photo→vision→identify→place core loop | ✅ full design pass | ✅ **first campaign to drive it** | — |
| Book identity subsystem (books.ex, moderation, workers) | ✅ full design pass | partial | — |
| SPA shell (Main/Login/Route/nav/onboarding) | ✅ full design pass | ✅ | — |
| Settings/session/GDPR | ✅ full design pass | ✅ (all 7 pages) | — |
| Test suites (3 stacks, 4,922 tests) | ✅ full inventory | n/a | probe + read verdicts |
| Wiring trace (8 boundaries) + zero-row sweep | ✅ | — | — |
| Token drift / dead code / knobs | ✅ | — | — |
| Absence pass (6 directions + lifecycle lenses) | ✅ | — | — |

**Surfaces driven: 30 of 34.** Not driven (all capped PARTIAL, none load-bearing for a wave): photo-path duplicate re-upload and not-a-book rejection (drive tooling died; `upload.spec.ts` covers both), full keyboard-a11y pass, notifications/audit-log resolved states. **Stack:** preview `stacks-core-pr-feat-staff-engineer.fly.dev`, Neon branch `br-odd-darkness-anjzliew`, Modal vision deployed and exercised.
**Baselines:** `just run mix test` 3,235 tests / 0 failures · `elm-test` 1,285 / 0 · preview seed emits events (event_log 316).

## The walkthrough (summary — full 30-row ledger with screenshots in the working ledger)

The core loop **works and is delightful**: drop a photo → vision identifies The Name of the Rose in ~25s → confirm with cover → placed on a beautiful shelf. Register→confirm→onboarding completes; password reset works end-to-end (doc claiming otherwise is stale); reset revokes sessions (W-7 fixed); manual ISBN checksum UX is right; privacy defaults are correct (no-enumeration 404); empty-state copy matches spec verbatim; the five rooms have real identities.

Against that: login **silently discards successful logins** in an occluded window and costs 4.6s at best; manual ISBN **bypasses duplicate detection**, and the resulting double placement **500s the owner's own book-detail endpoint** (all three symptoms verified live); a 0-byte upload rode the GPU repeatedly behind an infinite spinner; the price chain has produced **zero rows across three campaigns** (enum drift found to the commit); mid-form 401s still lie ("try again"); offline shelf navigation is a silent no-op and a hung request renders as *an empty bookcase*; the settings hub, Looking-for-a-Home, and About ship in a second, unfinished visual register — About literally says "Placeholder copy — the owner will refine this."

## Reconnaissance numbers

| Metric | Value |
|---|---|
| Tests | 4,922 (3,198 Elixir / 1,238 Elm / 486 Playwright); 59 config-excluded from default E2E run |
| Mutation probe | Broke all 5 production SSE wire fields → **1,285/1,285 still green** |
| 401 coverage | 22 of 38 pages; the 3 misses are the 3 settings write-forms |
| Dead code | 4 workers + reviews vertical ≈ 1,040 LOC prod + 890 LOC tests |
| Routes with no client caller | ~18 (incl. the dead deep verb `POST /api/books/confirm`) |
| Event registry | 22 of 55 emitted types (moduledoc claims "complete catalog") |
| Zero-row sweep | price_snapshots 0 · review_snapshots 0 · bookstore_events 0 · third_spaces 0 · embeddings 0 |
| CSS | orphan classes 398→**0** (gates landed) · 272 hardcoded hex · **0** spacing tokens vs 516 literals · 3 phantom tokens |
| Duplication | password rule ×9 · save-button ×6 · 401 handling ×22 · visibility literal ×3 · `{n,unit}` ×3 |
| Unturned knobs | 19, of which 4 are defects (EMAIL_FROM → **prod email non-functional**, argon2 pool unreachable, OBAN_POOL_SIZE over Neon ceiling, POOL_SIZE setter inert) |
| Story census | 7 in-scope story files with zero mapping citations; 5 launch-milestone intents with no story; 6 stories deny code that ships |

# Root findings

## ⛔ R1 — The auth credential is written downstream of a browser animation frame
`saveAuth` + post-login navigation are reachable **only** via `Promise.all` over seven WAAPI animations inside a `requestAnimationFrame` (`app.js:342,495-503` → `Main.elm:1200-1216`). Occluded window → rAF never fires → token minted server-side, never stored, submit permanently disabled (`transitionState` never resets, `Login.elm:650`). Best case: every login pays 4.6s before the credential exists. Back-button mid-animation silently discards the token. Siblings in the same class: forgot-password success rendered as camouflaged body copy with no live region; reset-password success destroyed by any keystroke (`ResetPassword.elm:61,64`). Register already does it right — persist state first, no animation gate (`Login.elm:317-319`).
**Symptoms explained:** W-1 (48s→∞ login), 3× discarded successful logins observed live, forgot double-send, reset ack vanish.
**Fix shape (design-it-twice resolved):** persist-first-then-animate + `AuthState = Anonymous | Authenticated Auth | Arriving Auth` (token loss unrepresentable) + sleep-race backstop. **Leverage:** kills the product's worst first impression and the whole silent-success class; ladder rung 8 → 1.

## ⛔ R2 — The book-identity deep verb exists, is correct, and is dead
`Books.confirm/2` (`books.ex:974`) already does duplicate detection, `find_same_work` merge, and atomic create-and-place. **Zero frontend or E2E references.** The live paths are client-side reassemblies that skip every invariant: manual ISBN → blind `place_book` (dup bypass → double placement → `Repo.one()` raise → **owner's book detail 500s, verified live**); `find_existing` is DB-only so **manual entry cannot add a new book at all** (valid ISBNs 404, "blaming the user"); vision path skips `find_same_work` → W-13 two-works duplicate (live in search today). Plus: two near-identical create transactions (one drops `google_books_id`), `verification_source` unrepresentable, `merge_edition` resolves externally then discards the metadata.
**Fix shape:** wire `POST /api/books/confirm` into the manual path (deleting the DIY flow) — one change, four fixes, using tested code; then denormalise `user_id` onto placements + `UNIQUE (user_id, book_id) WHERE removed_at IS NULL` (data repair first) as the unbypassable backstop; `verification_source` column (D1). **Leverage: highest of the plan** — core-loop correctness, rung 8 → 4.

## ⛔ R3 — Failure paths are structurally silent
`IdentifyBookJob`'s `{:error, reason}` branch touches neither the row nor the stream (`identify_book_job.ex:125-128`) — the only branch of three without a terminal path; no discard observer; SSE waits 360s against a job that died in 60. A 0-byte image passes three hops while `verify_object_exists` **already holds the size and discards it** (`books.ex:489`). `SCRAPE_OUTCOME_RATE_LIMITED` added to proto+Rust in commit `f28c032e` but not to `trigger_price_scrape_job.ex` → catch-all → retry loop → **price_snapshots = 0, third campaign running** (Elm codegen makes enums a closed type; Elixir codegen makes them `String.t()`). Resolver `_`-collapse records real books as `:invalid_book` during a Google Books 503 (`moderation.ex:467-471`). `Loading` renders the same view as an empty shelf (`Bookshelf.elm:522-527`) — a hung request shows "you own no books", forever (no `Api.elm` timeouts, no shell network state, zero online/offline handling). Metrics scrape 401s every 15s on preview. Notifications `init` returns `Loading` + `Cmd.none` when tokenless — spins forever.
**Fix shapes:** final-attempt-always-marks-terminal (structural, small) then closed vision error set; size gate one-liner; interim RATE_LIMITED clause then **proto-enum codegen for Elixir + lint coverage check**; resolver match on the closed error type; `Loading` view split + `Api` timeouts + shell connectivity banner (the `handleSessionExpiry` architecture, reused). **Leverage:** converts every "silent forever" into a visible state; unblocks prices.

## ⛔ R4 — A correct decision, hand-copied N times, with no gate reading the list
The 401 interceptor shipped correctly (#173/#178) and its *coverage list* was hand-written markdown: #178 "converted" a page that no longer exists and missed the three real stragglers — the three settings **write-forms** (2-tuple updates, no OutMsg). Same shape: save-button ×6 (two ellipsis glyphs — and `Profile.elm:318` already has the right abstraction, unpromoted), password rule ×9 sites/4 wordings, visibility as `Maybe String == "owner"` ×3 (a rename away from a silent privacy regression), `{n,unit}→seconds` ×3, export coverage guarded on one table's columns only, Elm-computed `--active` class thrown away by empty CSS.
**Fix shape:** each extraction ships **with its mechanical set-difference gate** (reflection test: authed page without `SessionExpired` fails; user-linked table absent from export fails; `user_id` column without conforming FK fails). **Leverage:** this is the recurrence-prevention root — #173 passed every existing gate with the defect live.

## ⛔ R5 — The seams between layers are untested by construction
Run-proven: all five production SSE wire-format fields broken → **1,285/1,285 Elm tests green**. Contract-proven: the BookDetail progress card is built from fields the proto/controller never send (blank in production; fixtures invent them). Factories bypass every changeset (editionless books violating the ISBN gate, ~90% checksum-invalid ISBNs, shelf/bookshelf desync in every fixture — which is why R2's constraint gap was invisible). The vision mock documents a steering API it doesn't have → five ad-hoc replacements + mock-echo tests. 11 of 13 mocks compile into the production release; `MockReviewFetcher` **is** the production implementation. The "SECURITY" read-only test's effect translator maps every Msg to `Cmd.none` — unfalsifiable. `rate-limit.spec` skips exactly when rate limiting is broken.
**Fix shape:** factories through changesets/public API; steerable vision mock; mocks → `test/support`; single wire format (snake_case) with fixtures derived from proto; export the real decoders instead of hand-mirrors; rewrite/remove the echo tests with named coverage; fail-closed rate-limit spec. **Leverage:** makes every later wave's green mean something — must precede the refactor waves.

## ⛔ R6 — GDPR: erasure and export have scope holes the guards cannot see
`op.uploaded_images.user_id` is a bare `:binary_id` — no FK, no erasure step, TTL-only deletion: **an erased user's image rows and R2 photo path survive up to 30 days**. The (excellent) `pg_constraint` erasure guard is blind to FK-less columns and excludes the `audit` schema (`audit_log.user_id` also bare). Export has **no table-level guard at all**: blog posts, comments, uploaded images, group memberships, and the audit log the product itself displays are all missing from portability. The audit-scrub trigger self-disarms after one row — the first scrub written will fail on row 2.
**Fix shape:** FK + erasure step + export additions now; widen the guard to `information_schema.columns` (FK-or-allowlisted); add the export table-guard; fix the GUC trap. **Leverage:** legal exposure on the core loop; extends the best guard in the codebase rather than rewriting it.

## 🟧 R7 — Built-but-not-connected is still the dominant waste class
Four dead workers + the reviews vertical (~1,900 LOC incl. tests, root cause "built → tested → never scheduled"); `ThirdSpaces.elm` orphan (no Route constructor, kept alive by its tests); the **entire blog subsystem and /groups are URL-only** (zero inbound nav links); ~18 routes no client calls (incl. `auth/me`, the superseded upload pair, the visibility-grants trio, US-1.7.1's shelf-move); `EMAIL_FROM` unset (prod transactional email non-functional per the code's own docs); Grafana dashboards auto-upload wired but unset; event registry at 22/55 with the upload pipeline's own `image.*` lifecycle unobserved; 27 generated proto modules unused while `/costs` and `/marketplace` hand-decode.
**Leverage:** ~2k LOC deletable; the wiring-trace set-differences become standing DoD checks.

## 🟧 R8 — The product has two visual registers, and every unhappy path lives in the second
Register A (login door, shelf rooms, spines, empty-state copy) is genuinely lovable. Register B: settings hub (the hub classes have ~no real CSS — `--active` inert so you can't tell where you are, `.success` unstyled, the mobile breakpoint doesn't exist), Looking-for-a-Home (flat void, breaks the five-shelf family), About (visible placeholder), authed home (= logged-out marketing page, documented drift), core-loop shelf-picker/format widgets (browser-default), "Add Book" **unreachable on touch** (CSS-only hover disclosure, no ARIA state), onboarding (promises a chooser it doesn't render; near-opaque scrim; `aria-modal` asserted with no focus trap or Escape), recovery legs absent (resend-confirmation + silent 24h account erasure; undo-remove; un-merge; cancel-deletion; photo delete; rate-limit UX). The line between registers tracks exactly whether a story specified the experience.
**Leverage:** Milestones B and D are blocked on several of these.

## 🟧 R9 — The story corpus, mapping, and token system drift with no gate in either direction
7 in-scope story files unmapped; 5 launch-milestone intents (invite-gating, Goodreads CSV, POSSE, FAQ page, feedback channel) have **no story**; 6 stories deny code that ships (both staleness directions); `implementation-mapping.md:1857` wrong four ways; `notes/` still cites two proof-points that are fixed. Token values ungated: 272 hardcoded hex (accelerating in the newest surfaces), no spacing scale, no semantic state tokens, incomplete type scale.
**Leverage:** every future plan reads these documents.

# Ladder wins (defects moved from "a test might catch it" to "it cannot happen")

| Finding | Caught today at | Moves to | Class eliminated |
|---|---|---|---|
| Duplicate placement | Nothing (rung 8) | **Rung 4** — `UNIQUE (user_id, book_id)` partial index | Every entry path, present and future |
| Token discarded after 200 | Nothing | **Rung 1** — `AuthState` type: `Arriving` holds a persisted `Auth` | "Logged in but not stored" unrepresentable |
| Enum drift (prices dead) | Rung 8 (silent retry loop) | **Rung 2/3** — Elixir enum codegen + lint coverage check | Every proto enum × every consumer |
| Erasure misses a user table | Rung 8 | **Rung 6→4** — `information_schema` guard + FK requirement | FK-less user columns, incl. future ones |
| Page forgets 401 | Rung 8 | **Rung 6 (structural)** — wrapper + reflection test | Page 23 next year |
| Fixtures encode impossible states | — | factories through changesets | Editionless books, desynced shelves, invented fields |
| Hung request renders as empty shelf | Rung 8 | **Rung 2** — `Loading` split from `Success []` in the view type | Every RemoteData consumer |
| Test code in prod release | Rung 8 | **Rung 5** — mocks in `test/support` only | `MockReviewFetcher`-class incidents |
| `toPath ∘ fromUrl ≠ id` | Rung 8 | **Rung 6** — property test over all routes | Route aliasing |

# The plan

Eleven waves. Sizes: XS < ½ day · S ~1 day · M 2–4 days · L ~1 week.

### Wave 0 — Eight small fixes with outsized payoff (XS each)
**Why first:** each is independent, needs no design, and closes a live defect.
| Item | Root |
|---|---|
| 0a. Fix preview/prod metrics scrape auth (`/internal/metrics` 401 loop) | R3 |
| 0b. Set `EMAIL_FROM` (prod email currently cannot deliver) + document in runbook | R7 |
| 0c. Stop `deploy-stack.sh` setting `SMOKE_TESTS_ENABLED` unconditionally in prod | R7 |
| 0d. Interim `SCRAPE_OUTCOME_RATE_LIMITED` clause in `trigger_price_scrape_job.ex` (mirror ROBOTS_BLOCKED) | R3 |
| 0e. Reject 0-byte/undersized uploads in `verify_object_exists` (size already in hand) | R3 |
| 0f. Delete `UserMenu.elm`'s inline `position: relative` (header reflow) | R8 |
| 0g. Move `viewProgressPanel` out of `.reading-pile__scene` (floating card) | R8 |
| 0h. `Notifications.init` → `NotAsked` when tokenless (stuck-Loading) | R3 |

### Wave 1 — GDPR completion — **STRUCK by owner, 2026-07-30**
Owner ruling: revisit the R6 GDPR findings once everything else is implemented. The findings stand in the record (uploaded_images erasure miss, export table gaps, guard blind spots, audit-scrub trap) and are deliberately deferred, not dismissed. Nothing else in the plan depends on this wave.

### Wave 2 — Deletions (S–M, ~2k LOC out)
**Why before refactors:** never refactor or test code being deleted.
Three dead workers + tests (`RecalculateWearJob`, `ConfirmDeletionJob`, `FetchReviewsJob`) + the reviews mock scaffolding (per owner ruling D6 — story survives, re-scoped in Wave 10) + orphaned `spine_data/1` + its 200 test lines; `Route.Settings` collapse (one parser line; kills 20 duplicated init lines + the sidebar-highlights-nothing bug); `LogoutCompleted` → `FocusResult` idiom; 3 phantom CSS tokens; 4 dead env vars; superseded upload route pair (`POST /api/upload`, `/upload/identify`) after confirming no callers; stale comments (`Api.elm:688` presigned-URL fiction, enrichment-diagnostics tag comment).
**Owner ruling 2026-07-30: `DiscoverBookstoreEventsJob` is NOT deleted — it is wired** (moved to Wave 11e: cron entry + structured extractor replacing the raw-regex path per the research doc + read endpoint from `Enrichment.Events`' unused functions).

### Wave 3 — Test architecture (L)
**Why before contracts and refactors:** guarantees must mean something before code moves under them.
Factories through changesets/public API (kills editionless books, desynced shelves, invalid ISBNs); steerable vision mock (delete the five ad-hoc replacements); all mocks → `test/support`; SSE wire format: snake_case only, fixtures derived from proto, delete the camelCase branch (probe-proven unguarded); export `Api.elm`'s real decoders to tests (delete the 5+6 hand-mirrors); rewrite the read-only SECURITY test with a real effect translator + positive control; rate-limit spec fail-closed; remove/rewrite the named mock-echo tests (each with a coverage note); decide the never-running `:sla` test; fix the false `:pending_apply_metadata_hardening` comment; add the reset-token consumed-second-use test (behaviour verified live; guarantee missing).

### Wave 4 — Contracts and constraints (M–L)
**Why here:** migrations ripple outward; several are preconditions (R2's index; D3's edition reference).
**Multi-shelf placement model (owner ruling 2026-07-30, replacing the earlier unique-per-user proposal):** the same book MAY legitimately sit on multiple bookshelves; two copies of the same ISBN on the SAME bookshelf stay forbidden (the existing `(book_id, bookshelf_id) WHERE removed_at IS NULL` index already enforces this at rung 4 — keep it). Work: de-raise `get_placement_for_book/2` and make every consumer handle a *list* of placements (fixes the live 500 on the owner's book detail); book detail highlights when a book sits on 2+ of Library/Antilibrary/Reading Pile/Wish List, with per-placement remove affordances; search's collection annotation names all shelves instead of collapsing to one; the "Already in Your Library" notice becomes informational parity across BOTH entry paths (photo already has it; manual ISBN gains it) — inform, never block. Plus: `book_editions.verification_source` NOT NULL backfilled (D1); `placements.book_edition_id` (D3 precondition); FKs: `auth_token_families.user_id`, `guardian_tokens.sub` owner; `lower(email)` unique index; ISBN checksum CHECK; **proto-enum codegen for Elixir + coverage lint in `lint-proto.sh`** (second drifted consumer already exists); event-registry completeness (register or explicitly-ignore the 33, decide `image.*` observers; fix the moduledoc's false claim).

### Wave 5 — Book identity: wire the deep verb (L)
**Why after 3+4:** needs honest fixtures and the new constraints as its net.
Wire `POST /api/books/confirm` into the manual path, delete the DIY lookup-then-place flow (fixes: manual-cant-add-books, dup-bypass UX, W-13 at source); unify `create/1`/`create_confirmed_book/4` (restores `google_books_id`); terminal-failure shape B (final-attempt always marks rejected) then shape A (closed vision error set; sidecar distinguishes undecodable from transient; align SSE timeout with job death); resolver-collapse fixes incl. `moderation.ex`'s `:invalid_book` mislabel; `merge_edition` keeps its resolved metadata; provisional-title UI treatment (D1); extract `Stacks.Books.ISBN` + `Stacks.Uploads` (~370 LOC; makes `books.ex`'s contract statable).

### Wave 6 — Session UX + the deduplication sweep (L)
**Why after 3:** the AuthState refactor needs trustworthy Login/Session tests.
Persist-first login + `AuthState` type + sleep-race backstop + reset the transition trap + `redirectAfterLogin`; title derived from `Page` (closes six route/content divergences); `Arrival` type replacing the six notice booleans + five inits; `decodeFlags` → `CorruptStoredAuth` surfaced; forgot-ack as a real `role="status"` notice + reset-ack keystroke fix + auto-advance; **authed-request wrapper + the reflection gate** + convert Profile/Password/Notifications (the three write-forms); `Loading` ≠ empty in every shelf view + `Api` timeouts + shell connectivity banner; promote `Profile.viewSaveButton` to `Components/` (fix its dead Success button) — retiring the ×6 copies; single password-rule source (9 sites); `Visibility` custom type at the boundary (3 magic-literal sites); `Duration.to_seconds/1` (3 copies).

### Wave 7 — Recovery and the unhappy paths (M)
**Why after 5/6:** upload-failure UX consumes Wave 5's terminal events; notices use Wave 6's components.
Build resend-confirmation (US-14.4.2: endpoint + login-card affordance + rate limit + no-enumeration; replace the "register again" copy; reconcile with the silent 24h erasure — a user must be able to recover before deletion); upload failure states (distinct copy for undecodable / not-a-book / service-down; no more 6-minute spinner); forgot-password double-send dedup; rate-limited (429) UX copy; W-10 distinct copy per failure cause on the settings forms.
**Owner rulings 2026-07-30 on the four recovery legs:** (1) undo-remove — **SPEC**: "Removed — Undo" toast, a few seconds, in-UI (build here); (2) un-merge — **SPEC, owner-only**: a platform-owner data-correction process, not public UI (admin surface; story written in Wave 10, built here or as an admin follow-up); (3) cancel-deletion grace — **EXCLUDE**: immediate erasure stays (record in mapping); (4) user photo deletion — **EXCLUDE publicly**; a follow-up must verify the automatic deletion path actually works (folds into the deferred GDPR revisit; record in mapping).

### Wave 8 — First impressions and navigation (L)
**Why after 6:** nav rebuild uses the Elm-owned disclosure pattern Wave 6 establishes for menus.
Nav IA: Elm-owned disclosure (button + `aria-expanded` + model state; delete `:hover`-only reveal), **"Add Book" as a persistent primary action** (currently unreachable on touch), Search top-level, bookshelves grouped, user menu exposes the settings family; onboarding rebuilt per D2 (upload + consent steps, real chooser or honest retitle, scrim to ~0.55+blur, focus trap + Escape to match `aria-modal`, spec'd dots); authed home gets a reason to exist (shelf preview / continue reading / add-book CTA — resolve the documented US-15.1.1 drift); settings hub styled + IA (fold Consent into Privacy; You/Privacy/Your-data groups; real `--active`; one nav idiom with a real breakpoint); Looking-for-a-Home joins the shelf family (US-18.1.1); About page real copy (Milestone B surface); side-by-side verification layout (US-1.1.1:16); empty-state CTAs become actions; upload picker/format widgets styled; remove the design-spec sentence shipped as copy; a11y follow-through (US-19.1.1/2 gaps: grid arrow-keys decision, `aria-live` upload progress, "Deep search" name).

### Wave 9 — Token system (M)
**Why late:** batch-coherent, and Wave 8 creates the new surfaces that must adopt it.
Spacing scale (516 literals, zero adoption — greenfield); semantic state tokens (one error red, success, warning); type-scale extension past 2.5rem; pill radius; migrate the 97 exact-duplicate hex occurrences (`#a09070` ×71 first); indicator-no-transition + no-`transition: all` rules; **the value-level third CSS gate** (hardcoded token duplicates, phantom vars, fallback-definition mismatches).

### Wave 10 — Documentation, stories, and the mapping (M)
**Why here:** records the decisions the earlier waves made; several items are the campaign's 1c obligations.
Map the 7 unmapped stories; correct `implementation-mapping.md:1857` (four errors) + the phantom `US-11.2.1`; refresh the 6 self-denying stories (US-14.3.2, US-10.2.1, US-8.5, US-2.5.3, US-6.1, US-14.4.1); write the missing launch stories: invite-only registration, Goodreads CSV import, POSSE/Substack, platform FAQ/About, beta feedback channel; write stories/ADR-references for the shipped-unstoried clusters (transparency/insights, admin MFA, auth-hygiene jobs incl. the 24h erasure behaviour, DiscoverEditionsJob, catalogue); re-scope US-2.1.1 reviews source (D6); fix the event-registry moduledoc; correct `notes/phase-1-launch-extension.md:16-20`'s two stale proof points; record the deliberate exclusions below **in the mapping** so they stop resurfacing; document the 20 read-but-undeclared config keys; re-scope #091 to include scalar knobs.

### Wave 11 — Launch gates (L+, from the existing backlog)
**Why last in this plan:** feature work gated on Wave 10's stories; most items already exist in the backlog and are re-pointed, not re-invented.
Invite-only registration (Milestone D); Goodreads CSV import (through the ISBN gate); POSSE/Substack MVP (canonical export / RSS); production deploy execution (#163 runbook); beta feedback channel; backup/restore verification (#066); **wire the bookstore-events vertical (owner ruling 2026-07-30):** cron entry for `DiscoverBookstoreEventsJob`, replace the raw-regex extractor with the structured path (schema.org/Event → .ics → LLM, per the research doc), read endpoint from `Enrichment.Events`, surface on book detail/third-spaces as appropriate. Existing issues #191 (rewrite stale summary first — Wave 10) and #066 fold in here.

# Deliberately not in this plan

| Item | Why |
|---|---|
| Third-spaces map page (G1 steps 5–6) + `ThirdSpaces.elm` orphan | Out of Phase 1 frame; carried unchanged from prior plan's Wave 6 assignment (tile proxy → port → page). The orphan page is that epic's raw material — do not delete. |
| Bookstore-events vertical routing (US-2.4.1) | Phase 2 scope, owner ruling D7; only the dead *worker* is touched (Wave 2, flagged for a nod). |
| Vision architecture redesign / JEPA, eval harness | `notes/` E.3: post-launch, eval-gated research track. |
| Marketplace / enrichment / metrics validation epics | `notes/`: "not on the launch path." |
| Community-moderation "Wikipedia model" | `notes/`: deferred as a scale feature. |
| Non-ISBN readables | `notes/product-ideas.md:153-156` self-defers pending a design doc + ADR. |
| Age-gate Verify affordance | Withdrawn by ADR-020 §2; provider flow tracked in #069. |
| Kafka/K8s-class generality | Verified absent — the ceilings are already honoured; nothing to delete. |

**1c gate accounting:** all 34 absence-pass items are disposed — items 1–5, 19–29, 32–34 → Wave 10; 6–14 → Waves 5–8; 15–18 → Wave 7 owner decisions; 30–31 → exclusions table / Wave 10.

# What this costs and what it buys

Honest total: **roughly 9–13 engineering weeks** across eleven waves (0: days · 1: M · 2: S-M · 3: L · 4: M-L · 5: L · 6: L · 7: M · 8: L · 9: M · 10: M · 11: L+, partly existing backlog). Waves 0–2 are a week combined and remove the legal exposure, the GPU waste, dead prod email, and ~2k LOC.

What it buys, concretely: a core loop whose invariants live in the schema instead of in whichever client remembered them; a login that cannot lose a minted credential; failure states a person can see; a test suite whose green light covers the wire formats production actually uses; GDPR erasure and export that reach everything user-linked, with guards that catch the next table automatically; one visual register instead of two; a story corpus and mapping a planner can trust; and the five launch-blocking features storied and sequenced. At the end, the phrase "complete ≠ verified" in `notes/` stops being true of Phase 1 — which is the frame.

# Execution

On approval: Stage 7 files **one epic issue per wave** via `create-issue` (children spun out by the orchestrator's Epic Parallel Execution), the persona's bar written into every DoD (live drive for user-facing waves; mutation probe on load-bearing assertions; wiring trace + zero-row sweep for pipelines; `gdpr-review` for Waves 1/4/5; `staff-review` per issue, advisory). Execution = Mode E (`staff-execute`), `just wave-status staff-campaign-2026-07-30` as the completion authority. Preview stack `stacks-core-pr-feat-staff-engineer` to be torn down after filing (`scripts/cleanup-preview.sh --branch feat-staff-engineer`).
