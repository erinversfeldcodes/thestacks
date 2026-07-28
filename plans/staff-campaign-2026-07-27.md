# Staff Engineer Campaign — Remediation Plan
**Date:** 2026-07-27 · **Scope:** Phase 1 — original (MVP) **and** extended
**Supersedes:** `plans/staff-campaign-2026-07-26.md` (its ROOT 3 drive-evidence is **retracted** — see Retractions)
**Also absorbs:** `plans/wave-0b-remaining-spec-2026-07-28.md` (folded into Wave 0b's resolution section; that file is now historical detail only)

## Wave 0 status — verified against the code, 2026-07-28

⚠️ **I had described Wave 0d as "complete (P1–P10)". It is not**, and two Wave 0c items fell through
the crack between 0c and 0d. Every row below was checked against the tree, not against a previous
claim.

| Sub-wave | Verdict | What is actually left |
|---|---|---|
| **Wave 0** | ✅ **COMPLETE** | Both items landed *and* tested. Session revocation lives in `Stacks.Email.reset_password/2` (`email.ex:167`), not the controller the plan suggested; `email_test.exs:124` asserts a pre-reset token then fails with `:session_revoked`. CSP carries `https://archive.org https://*.us.archive.org` (`security_headers.ex:17`) |
| **Wave 0b** | ❌ **INCOMPLETE — the only outstanding sub-wave.** Re-verified against code 2026-07-28 | G5, G4-client and G6-UI all still have **no client call at all**; G3 has an evidence gap; G1's data layer + ADR are **in** (steps 1–4) with the port and page in a later wave, and one ⛔ chain break of my own — see the zero-row sweep |
| **Wave 0c** | ✅ **COMPLETE** | C1/C2/C5/C6/C7/C8 done 2026-07-27; **C3 and C4 completed 2026-07-28** after being found orphaned — see below |
| **Wave 0d** | ✅ **COMPLETE** | P1–P10 all done. ⚠️ Three of the four items recorded as "remaining" were **already done and the note was stale** — see the closure table |
| **Wave 0e** | ✅ **COMPLETE** | E1/E2/E3 done; E5 decided (stays `0`); **E4 deliberately held for the launch gate**; E6 optional and skipped |

### ❌ What is still outstanding in Wave 0 — verified against code, 2026-07-28

⚠️ **Wave 0 is NOT closed.** Waves 0, 0c, 0d and 0e are; **Wave 0b is not**, and an earlier report of
mine said "Wave 0 is closed" when it meant "the six 0c/0d items are closed". The distinction matters
because 0b is the wave that makes built features *reachable*.

| # | Item | Server/back end | What is missing | Size |
|---|---|---|---|---|
| **G5** | Shelf organisation (#190) | ✅ done — 35 tests, full CRUD, **90 seeded `op.shelves` rows** | ⛔ **no `/shelves` client call exists at all.** `Api.elm` has bookshelf-level calls only (`:159`, `:831`, `:1571`, `:2423`) — nothing for the physical-shelf sub-resource. Decided: drag-and-drop **and** explicit controls, split by action | L |
| **G4** | RSS feeds | ✅ done and proven — `op.feed_cache` populated | ⛔ **no `/feeds` call in `Api.elm`.** Plus two conformance holes filed separately (no `rel="self"`, no per-entry link) | S |
| **G6** | Business opt-out | ✅ server done (`a435e2b2`) — domain-verified removal requests | ⛔ **no page and no client call.** Needs the submission form, the owner review queue, and extending the verified path to the `third_space` row (soft-delete) | M |
| **G3** | Source discovery | ✅ cause found and fixed — was cron-only, now also event-driven off `book.created` | 🟧 **zero-row DoD unproven: `op.discovered_sources` = 0.** The mechanism is wired; nothing has exercised it against a real Brave API key. Not a code gap — an evidence gap | S |
| **G1** | Third spaces | ✅ coordinates, geocoder, producer, **ADR 022** (steps 1–4) | ⛔ **no bookshop has coordinates**, so the 500 m rule can never fire — my own chain break. Then steps 5–6 (Elm port, map page) in a later wave, gated on rows existing | S then M |

**Zero-row sweep, local DB immediately after a from-scratch seed:**

| Table | Rows | Reading |
|---|---|---|
| `op.feed_cache` | **3–4** | G4's server side works. ⚠️ Timing-dependent, see caveat below |
| `op.shelves` | **90** | G5's backend has data; nothing can reach it |
| `op.discovered_sources` | **0** | G3 unproven |
| `op.third_spaces` / `third_space_events` | **0** | G1, expected — deferred |
| `op.bookstore_events` | **0** | Expected: the events job is deliberately unscheduled (C3) |
| `op.price_snapshots` | **0** locally | Proven on a **preview** earlier (first row ever); local is 0 because no scrape ran here |

⚠️ **Caveat on the `feed_cache` number, because it is not a stable 4.** `mix run seeds.exs` exits while
Oban jobs are still in flight: after the last run, `oban_jobs` held **214 completed and 6 still
`executing`** RegenerateFeedJob rows, and the E2E user's `library` feed was among the six — hence 3 rather
than 4. So the local count is 3–4 depending on timing, and the *reliable* proof of G4 is the deployed path
(`seed_live/0` on a node where Oban keeps running), not this one. Worth knowing before anyone treats a
local count as the DoD.

### ✅ Waves 0c and 0d closed — 2026-07-28. What each item actually turned out to be

`just run just verify` exit 0 (all gates including 240 dbt tests and `lint-dbt`).

| Item | Filed as | What it was | Evidence |
|---|---|---|---|
| **C3** | route the events job through the compliant egress | ✅ **real and unbuilt** | New `POST /fetch` on the scraper, `ScraperClient.fetch_page/2`, job rewired. Probe: removing the config gate fails "a store with no scraper config is never fetched" |
| **C4** | `robots_blocked` becomes a store state | ✅ **real and unbuilt** — the column existed, nothing wrote it | `record_robots_block/3` + `clear_robots_block/1`, two new proto fields. Probe: dropping the clear call fails "a lifted disallow resumes" |
| **P3** | canary assertion + delete the `scraper_module` coupling | 🟡 **half stale.** The canary *was* wired (`trigger_price_scrape_job.ex:166,191`) and tested. The coupling was not a coupling — but hid a real defect | See below |
| **P7** | edition discovery from Open Library, capped | ✅ **real and unbuilt** | `ISBNResolver.editions_for_work/1` (fetch capped at 50, one page) + `DiscoverEditionsJob` (creation capped at 10), event-driven off `book.created` |
| **P8** | an Oban job must rebuild the index on a cadence | ❌ **stale** — already done | Cron `30 4 * * *` **and** event-driven on `SCRAPE_OUTCOME_INDEX_REQUIRED` with Oban dedup (`trigger_price_scrape_job.ex:230`) |
| **P9** | record the four unscrapable targets as `:none` with a reason | ✅ **real and unbuilt**, and bigger than filed | New `unscrapable_reason` field; **nine of eleven** seeded stores named a nonexistent config |

**P3's real defect, which the filed description pointed away from.**
`store.scraper_module || store.name` (`trigger_price_scrape_job.ex:124`) substituted a **display name**
("Exclusive Books") for a path-derived registry key ("za/exclusive_books"). Those never match, so every
ISBN × unconfigured-store pair was a guaranteed `404 store not found` — and because the client melts a
fuse on a non-200, **a store nobody had configured could open the breaker for stores that were**. The
fallback existed to be safe and was the opposite. Replaced by `Prices.scrapeable_stores/0`, which filters
in the query so a new caller gets it right without knowing.

**P9 was the same defect at rest.** Nine of eleven seeded stores carried a `scraper_module` naming a TOML
that does not exist, and `scraper_module_keys_test.exs` *deliberately permitted* it — "a store whose
config has not been written yet, which is expected and visible". It was neither: it was nine guaranteed
404s. The invariant is now enforced pre-merge in both directions (`scraper_module` is non-nil **iff** a
TOML exists), which converts a silent runtime failure into a rung-3 one.

⚠️ **A vacuous test of my own, caught by a probe.** The P7 creation-cap test used hand-typed sequential
ISBNs whose **check digits were wrong**, so every one was refused by the ISBN hard gate before the cap was
consulted — `created <= 10` held because `created` was 0, and the test passed with the cap **deleted**. It
now generates valid ISBN-13s and fails with `got 20` when the cap is removed. Recording it because the
probe was aimed at the cap and found the test instead; without it this would have shipped as coverage.

**Not done, deliberately:** `DiscoverBookstoreEventsJob` remains **unscheduled**. C3's scope was the
egress, and the plan's own rule was "fix the egress *before* anything wires this job up". Scheduling it
starts crawling real bookshops, several of them one-person operations — a deliberate act, not a side
effect of closing a compliance item. The wiring belongs to whoever turns the events feature on.

### How C3 and C4 were lost in the hand-off from 0c to 0d

Both are *mentioned* in Wave 0d's prose and neither has a row, a size, or a status. That is how they
went unbuilt while both waves read as done — the same "moved and then untracked" pattern this campaign
warns about for issues.

**C3 — was an unguarded egress; fixed 2026-07-28.** `discover_bookstore_events_job.ex:74` was a bare
`Finch.build(:get, url, [{"Accept", "text/html"}])`: no robots check, no rate limiter, no fuse.

⚠️ **Severity is real but latent, and the reason matters:** the job has **no enqueue site and is absent
from the crontab** — the only references to `DiscoverBookstoreEventsJob` anywhere are its own log
lines. So nothing is being scraped non-compliantly today. The rule stands as originally written:
**fix the egress before anything wires this job up.** Whoever wires it will not think to check.

**C4 — was a column that nothing populates; fixed 2026-07-28.** `robots_blocked_path` existed as proto
field 15 and as a generated schema field, and **nothing in `apps/core/lib` wrote or read it**. Two of the three intended fields (`matching_rule`, `observed_at`) were never added, and the
probe-cadence re-check does not exist, so a `robots_blocked` store cannot resume by itself.

This is a **zero-row instance of exactly the ROOT G shape** — built halfway, wired to nothing — sitting
inside the wave that was meant to eliminate that class. Worth stating plainly: the schema change was
the easy half, and shipping it alone produced a column that reads as a feature.

## ▶ RESUME HERE — 2026-07-28 (updated). Wave 0b's three G-items are BUILT

`just run just verify` is **exit 0**. Nothing is half-landed.

### ✅ Done since the last resume point

| Item | Commit | What landed |
|---|---|---|
| **G4** feeds | `d9d4a9a8` | ⚠️ The blocker was not a missing call: profiles are addressed by **handle**, the feed endpoint was keyed by **user_id**, so the URL was unbuildable from the page. Added `GET /api/feeds/u/:handle/:bookshelf_name` (canonical, declared before the UUID route so `u` is not swallowed as an id), plus `has_feed` on each bookshelf summary and an anchor — not a fetch — on the profile |
| **G6** removal form | `9707b599`, `155d187a` | The ⛔ half first: a verified removal excluded the *source* and left the `third_space` on the map. Now soft-deleted (`opted_out`), never hard-deleted, because discovery re-finds and would re-list. Plus `/listing-removal`, unauthenticated, and the discreet "Is this your business?" link |
| **G6** review queue | `0ef9491d` | Parked requests were in **no payload at all** — invisible to the only person who could act. `pending_removal_requests/0` + `honour`/`decline` endpoints |
| **G5** shelves | `703cc82e` | `Api.elm` now has all four shelf calls, so 90 seeded rows and 35 backend tests are reachable. Drag **and** arrow buttons, both driving the same pure `moveUp`/`moveDown`/`moveTo` |

### ❌ What is left, and neither is a code gap I closed alone

1. **The review queue has no admin UI.** `GET /api/admin/removal-requests` and the two
   decision endpoints are live and tested; nothing in Elm calls them. **This is the same
   built-but-unreachable shape as the items above** — the server half is done and the queue
   is still invisible to the owner in practice. Add it to `Page/Admin/*` alongside the
   existing `/admin/sources` surface.
   ⚠️ **Naming hazard, do not collapse:** `PUT /sources/:id/approve` **publishes** a
   listing; `PUT /removal-requests/:id/honour` **takes one down**. Same-sounding, opposite
   effect, same row. The endpoints and context functions are deliberately named for what
   happens to the *listing* (honour / decline), and a test asserts they are distinguishable.

2. ⛔ **None of the three has been driven live.** Every G-item's DoD in this plan is the
   **render check** — the value appearing in a browser — and all three are verified by test
   and compile only. That is explicitly *not* the bar this plan sets, and the campaign's own
   lesson is that code-reading and green tests both lie about reachability. In particular:
   - **G5's drag-and-drop cannot be validated by unit tests at all.** The pure move
     functions are tested hard; whether a drop actually fires in a browser is untested.
   - G4's subscribe link needs a real feed reader, or at least a real 200 from the handle URL.
   - G6's form needs one end-to-end submission of each outcome.

   Stand up a preview (`bash scripts/deploy-preview.sh`), drive all three, and record
   "N of M driven" per the Drive section of `docs/agents/staff-engineer-agent.md`.

### Still parked, deliberately, and not blocking

| Item | Why |
|---|---|
| **G3 evidence** | 5 pending sources now seeded so `/admin/sources` has rows; proving discovery end-to-end needs a real Brave key in a deployed environment |
| **G1 steps 5–6** | Elm port + map page, a later wave. ADR 022 settled the tile/geocoder question; rows now exist |
| **E4** remove `noindex` | Wave 9 launch gate; blocker E2 cleared |
| **`DiscoverBookstoreEventsJob` schedule** | Starting it crawls real bookshops, several one-person operations. Owner's call |
| **Bookshop branches + `city`** | Data-model gap: chains need per-branch rows, and 3 shops did not geocode for want of a city. Same root cause |
| **RSS conformance** | No `<link rel="self">` (RFC 4287), no per-entry link. Filed separately, not folded into G4 |

### ⚠️ Gotchas this session paid for

1. **`just run just proto-sync-all`** — all four codegen steps plus the four manual
   follow-ons it cannot do. Use it instead of remembering the order.
2. **A hand-written changeset silently drops a new column.** Guarded now by
   `changeset_field_coverage_test.exs`; the guard only helps if the suite runs.
3. **dbt `source-has-all-columns` caught me three times.** Every new column needs an entry
   in `dbt/models/staging/sources.yml`.
4. **`git add` a generated migration immediately** — `mix test` deletes untracked
   `_add_*_to_*` files. `proto-sync-all` does this now.
5. **`proto.sync` can emit two migrations in the same second**; Ecto rejects duplicate
   versions. Bump one timestamp by hand.
6. **The PII lint will refuse free text in an event payload.** `event_log` is immutable, so
   a URL in it is permanent — key events by id and carry no payload where possible.
7. **`update_all`'s `:returning` came back nil.** Select the ids first; do not rely on a
   driver capability that fails silently.
8. ⚠️ **Vacuous tests are the recurring self-inflicted wound — five this session.** ISBN
   check digits, the limit-ordering decoys, the geocoding cap, and twice a *comment* claimed
   a guard that a probe showed was not load-bearing (`moveTo`'s clamp; the "off-by-one" it
   supposedly prevented). **Probe every load-bearing assertion.** Writing the reason in a
   comment is not evidence the reason is true.

## Amendment log

| Date | Change |
|---|---|
| 2026-07-27 | Original plan. Waves 0–9, owner decisions D1–D3. |
| 2026-07-27 | Waves 0c/0d added — robots.txt compliance made structural, price fetch rebuilt on the capability probe. G2 proven live (first `price_snapshots` row ever). ⚠️ **Recorded as "completed" at the time; a 2026-07-28 code check found 0d has four open items and that C3/C4 were orphaned. See the Wave 0 status table above.** |
| 2026-07-27 | 🟧 **ROOT H narrowed then closed** — challenged correctly by the owner; all three non-staleness cases made event-driven. This removes the correctness argument for `min_machines_running = 1`; see Wave 0e/E5. |
| 2026-07-28 | **Wave 0b resolved** — G1/G4/G5/G6 specified; G4 and G6 server halves built and merged (`a435e2b2`); **G1 removed from Wave 0b** as not promotable. `docs/user_stories/US-3.1.1-third-spaces-map.md` written, all six of its decisions taken. |
| 2026-07-28 | **G1 brought fully in** (owner: *"let's bring it all in"*). Steps 1–4 done — coordinates + indexes, Nominatim behind a swappable seam, approval-driven producer, **ADR 022**. Bookshops geocoded (7/10). Chain proven live: `third_spaces` 0→1 with `nearest_bookshop_km` 0.678 km. The 500 m rule became **two tiers** (distance OR curation). `discovered_sources` 0→5 seeded, closing G3's zero-row cause. Added `just proto-sync-all` + a changeset-coverage guard. **See ▶ RESUME HERE above.** |
| 2026-07-28 | **Waves 0c and 0d closed** — C3, C4, P7 and P9 built; P3 half-stale (its real defect was a fabricated registry key); P8 already done. `just run just verify` exit 0. ⚠️ **Wave 0 as a whole is still open: 0b remains** — an earlier report of mine said "Wave 0 is closed" and meant only these six items. |
| 2026-07-28 | **Wave 0e added** — production domain cutover. Six items, four wrong in production today. ⚠️ Two of the six reported items were *not* what the report described (E1's RSS half, E5's severity), and my own first framing of **E2 was overstated as ⛔ and is corrected in place to 🟧** — the root `robots.txt`/`ai.txt` are repository-level declarations, not unserved website files. |

## The frame

**Make Phase 1 genuinely launch-ready — verified rather than claimed — so the closed beta can invite
real users who can add their books and recover their own accounts.**

`notes/phase-1-launch-extension.md`: Milestone A is literally *"Verify + complete the core"* and is
first *because* "claimed complete ≠ verified" (lines 10–20), naming #112/#114/#115/#116 (MVP) and
#125/#126/#127 (extended) — precisely this scope. Milestone D gates the beta on account recovery
(line 83). Line 41: *"budget for the fixes, not just the tests."*

**Ordering principle:** prove what is real → fix what silently breaks a stated guarantee → complete
what blocks the beta → then pay down the drift that makes the next change expensive.

## Coverage — read before trusting any wave

| Area | Surveyed | Driven live | Probed |
|---|---|---|---|
| Extended surfaces (auth/nav/errors/settings/a11y) | ✅ | **42 of 44 in-scope** | 1 mutation probe |
| MVP: upload page, ISBN gate, manual entry, search, book detail, spines, shelf actions | ✅ | **~14 of 26** | — |
| MVP: photo→vision→identify→place (US-1.1.1) | ✅ code | ❌ **not driven** | — |
| MVP: duplicate detection, bulk upload, multi-format merge, shelf transitions, age-gated flagging | ✅ code | ❌ not driven | — |
| `Stacks.Books` + ISBN/vision pipeline | ✅ full design pass | partial | — |
| MVP test suite + coverage map | ✅ full | n/a | — |
| Simplification / dead code | ✅ full, every candidate `notes/` goal-checked | n/a | n/a |

**Stack:** preview `stacks-core-pr-feat-staff-engineer.fly.dev`, Neon branch `br-plain-bonus-anazu6e1`,
Modal vision deployed and wired.

**Honest edges:** ~12 MVP rows undriven, **most importantly the photo→vision loop itself** — so every
verdict about the vision path rests on code-reading plus the subsystem survey, not observation. Waves
touching it say so. Only **one** mutation probe was run this campaign (the reset-token guard, prior
session); the Test Critique verdicts below come from the coverage map, which is weaker evidence than a
probe. External state during the run: **Google Books quota exhausted** (its circuit breaker blown, Open
Library carrying 100% of resolution alone) — this makes ROOT A's risk acute rather than theoretical.

## Retractions from the previous plan
- **"A first-time visitor sees *The library closed your session*"** — **WRONG, struck.** On preview with
  clean state `/` renders the home page. Planting a stale token reproduces the notice *correctly*. My
  local Chrome profile held a stale token from earlier E2E runs; I inspected `localStorage` after the
  app had already cleared it. ROOT 3's *design* finding (notice booleans) stands on read evidence; its
  user-visible bug does not exist.
- **"The Chrome MCP has no network emulation"** — wrong. `javascript_tool` + patching
  `XMLHttpRequest.prototype.send` gives a true `NetworkError` (`fetch` is a no-op for `elm/http`).
- **"US-1.5.4 is a phantom story"** — wrong. No per-story *file*, but fully documented at
  `implementation-mapping.md:813` plus five other references.

## Reconnaissance numbers

| Metric | Value |
|---|---|
| Elixir suite baseline | 2,957 tests, 15 properties, 0 failures |
| Extended census | 22/22 claimed stories mapped; **24 files exist in §14–19 → `US-14.4.1`, `US-14.4.2` unmapped** |
| MVP census | **5 story files unmapped**: `US-1.6.1`, `US-1.6.2`, `US-1.6.3`, `US-1.6.6`, `US-1.7.1` |
| `Stacks.Books` | **1,373 lines, ~30 public functions, ≥5 responsibilities** — contract not statable in one sentence |
| ISBN entry points | **6**; 4 resolve externally, **2 do not** (`find_existing`, `resolve_isbn_candidate`) |
| Settings pages handling 401 | **3 of 6** |
| CSS | 41 tokens vs **89 hardcoded hex**, 3 phantom tokens, no spacing scale |
| Oban workers with no enqueue path | **4** |

---

# Root findings

## ⛔ ROOT A — The book-identity surface has no canonical "resolve-or-create" verb, so its stated guarantees are neither consistently implemented nor testable
**Leverage: highest.** One root explains six findings, it is the product's core loop, and it breaks the
one invariant `CLAUDE.md` calls non-negotiable.

| Symptom | Evidence |
|---|---|
| **W-11** Manual ISBN entry 404s for any book not already local, blaming the user for a valid ISBN | `show_by_isbn` → `find_existing/1` only (`book_controller.ex:248`, `books.ex:157-167`). Live: `9780156001311` → **404**; same ISBN to `POST /api/books` → **201** with real Open Library metadata. The capability exists; the UI never asks (`Page/Upload.elm:451-456` → `Api.lookupByIsbn`) |
| **W-14** The ISBN hard gate is bypassed on the barcode path, and "unverified" is unrepresentable | `moderation.ex:462-472` fast path skips `resolve_isbn` entirely; `store_book` commits a row titled `"ISBN …"`. No `verified`/`source` field on `Book`/`BookEdition`; the only trace is `title LIKE 'ISBN %'`, which vanishes when enrichment succeeds. `EnrichBookJob` `max_attempts: 5` with **no terminal-failure hook** |
| **W-13** A new ISBN of an existing work creates a duplicate **work**, not an edition | Two `op.books` rows for The Name of the Rose (ISBNs `…001311`, `…030410`). `find_existing/1` keys on `book_editions.isbn` alone |
| **M6** The duplicate is user-visible | Search "Rose" returns the title twice — Your Collection (1994) and On the Platform (1980) — as unrelated works |
| **W-17** The tests for the route cannot fail if the bug is present, and one canonises it | `book_controller_test.exs:502-546` pre-inserts the row; `upload_pipeline_test.exs:50-52` says *"Pre-insert … without hitting external ISBN APIs"*; `:513-515` documents the defect as intent; `UploadProgramTest.elm:290-308` is a **mock-echo**; `upload.spec.ts:529` uses one **seeded** ISBN |
| Error mapping duplicated 3× and lossy | `books.ex:314-320`, `:993-994`, `:1089` all collapse `:circuit_open` (both providers down) into `isbn_not_found`. **Acute now:** Google Books quota is exhausted, so "both down" is one OL blip away and would read to users as "your ISBN is invalid" |
| Creation transaction written twice, already drifted | `create/1` (`books.ex:174-226`) vs `create_confirmed_book/4` (`:1019-1069`) — the latter re-derives edition attrs by hand and **drops `google_books_id`** |

**Root:** there is no single verb meaning *"give me the book for this ISBN, resolving and creating it if
necessary"*. Six call sites each re-decide whether to look locally, remotely, or both — so a UI can
(and did) pick the wrong one, a fast path can skip verification entirely, and the test suite has
nothing to assert against.

## ⛔ ROOT B — Cross-cutting concerns are per-call-site convention instead of structure
**Leverage: high — a ladder climb that kills whole classes.**

| Symptom | Evidence |
|---|---|
| **W-5** 401 handling is per-page; 3 of 6 settings pages have none | `Password`/`Profile`/`Notifications`: 0 `isUnauthorized`, 0 `OutMsg`. **Masked on navigation** (the shell's own 401s redirect) and **bites mid-form**: `PUT /api/settings/password` → 401 → *"Could not change password. Please try again."*, stays put, keeps the stale token |
| **W-12** Every new user's books render greyed out as "hidden" | `hidden = placement.visibility == Just "owner"` — `Helpers.elm:151`, `:259`, `ReadingPile.elm:465`. **Three copies, none consults the shelf's visibility.** New shelves default to `owner`, so the predicate is true for every book. Contradicts `Spine.elm:315-321`'s own comment about "an otherwise-visible shelf" |
| **W-10** Three unrelated failures render identical copy | 422, 401 and a true `NetworkError` all produce *"Could not change password. Please try again."* — and "try again" is **wrong advice** for two of them (`Password.elm:169-176` `Failure _ ->`) |
| `document.title` wrong wherever content ≠ route | "Sign In" while Register shows; "Settings" on `/settings` vs "Profile" on `/settings/profile`; "Library"/"Password"/"Add a Book" while the login card renders |
| Same knowledge written N times | `{n,unit}→seconds` ×3 (two with no catch-all → crash on an unknown unit); 2 session-minting impls; password rules ×3 with 3 different messages; save-button state machine ×4; raw `data-testid` vs the `testId` helper |

## ⛔ ROOT C — Account recovery is incomplete, and the parts that work are unguarded
**Leverage: high — `notes/` line 83 makes this a Milestone D gate.**

| Symptom | Evidence |
|---|---|
| **W-7** A password reset does **not** revoke existing sessions | **Proven live:** mint session → `/api/auth/me` 200 → forgot-password → reset (200) → **`/api/auth/me` with the pre-reset token still 200**. The authenticated change-password path *does* revoke (`user_settings_controller.ex:64-68`) |
| Reset single-use works but nothing guards it | Replay → `400 invalid_token` ✅. But the mutation probe removing the guard left **all 76 tests passing**, and the coverage map independently found NONE. Correct code one refactor from silent regression |
| Resend confirmation does not exist | Zero implementation. `A7` shows the cost to users: *"Please register again to receive a fresh confirmation email."* |
| Rate-limited reset reports success | `email.ex:108-134` never binds the `with :ok <- check_rate_limit` result |
| Both stories unmapped | `US-14.4.1`, `US-14.4.2` appear nowhere in `implementation-mapping.md`; issue #191's summary is stale (its "no frontend / broken link" claims are false) |

## 🟧 ROOT H — Scheduled work cannot fire, but the consequence is mostly staleness

⚠️ **This section originally read "⛔⛔ Nothing scheduled can ever run" and overstated the
consequence. Corrected 2026-07-28 after the owner challenged it:** *"the cron is just to
refresh data, correct? … the only risk to `min_machines_running = 0` is that data is
stale, isn't it?"* Largely yes. The mechanism below holds; what it costs does not
generalise the way I first wrote it.

**Two things I had wrong:**

1. **Prices are already event-driven — by this wave's own P6 change.** `prices_for_work/2`
   enqueues a refresh *on read*, and the machine is awake by definition because it is
   serving that request; `BookCreatedHandler` enqueues on `book.created`. The 04:00 batch
   is now a redundant safety net, not the mechanism. I had not updated my own severity
   assessment after my own change.
2. **`ImageRetentionJob` is a safety net, not the GDPR mechanism.** Its moduledoc:
   *"Images are normally deleted immediately by IdentifyBookJob on success. This job
   handles edge cases where that didn't happen."* Calling it a compliance exposure was too
   strong; what lingers is stuck uploads, not routine retention.

**All three non-staleness cases are now fixed. `min_machines_running = 0` costs only freshness.**

| Job | Was | Now |
|---|---|---|
| ~~`BuildScraperIndexJob`~~ | No prices *at all* for four shops — the index dies with the process | ✅ Built **on demand**: `SCRAPE_OUTCOME_INDEX_REQUIRED` gained its own value so a lookup enqueues a build, deduplicated by Oban |
| ~~`ListingExpiryJob`~~ | Expired listings stayed `active`, so one showed as available and could still be bought — **wrong state**, not stale state | ✅ Expiry is a **read-time truth**: browsing and discovery filter it out, a single read reports `"expired"` so callers acting on status refuse it, and a seller still sees theirs to relist. Derived, never written — the answer follows from `expires_at`, so persisting it would be a second source of truth |
| ~~`ExpiredUnverifiedAccountsJob`~~ | Abandoned unconfirmed signups kept personal data indefinitely, and nothing user-triggered could substitute | ✅ **Registration reaps them.** It is the event most correlated with abandonment, so work arrives in proportion to the debt — and it fixes a UX bug at the same time: an abandoned account *blocked* a real one with "email has already been taken" for an account nobody owns |

Each remaining cron entry is now genuinely refresh-only, so the three retain value as
tidy-up (stored state eventually matches derived state) without anything depending on
them having run.

**A latent bug the signup tests exposed:** `maybe_assign_owner_role` always wrote a
**string** `"role"` key, so atom-keyed attrs became a mixed-key map that Ecto refuses to
cast (`expected params to be a map with atoms or string keys, got a map with mixed keys`).
It only bites for the *first* user on the platform — the owner branch — which is why the
controller's JSON string keys never hit it and no test noticed. Same class as the
`put_book_id` fix in P1: mirror the caller's key style rather than assuming one.

**Mechanism, unchanged:** `deploy/fly.core.toml` sets `auto_stop_machines = true` with
`min_machines_running = 0`. Oban's `Cron` plugin fires only while a node runs and does not
backfill missed windows, so a machine asleep at 08:00 never runs the 08:00 entry.
Everything *enqueued* while awake still executes — a job inserted by a request is picked up
by the running node, and anything left `available` is collected on the next wake.

**So the decision is smaller than I first made it.** For the enrichment jobs
(`DiscoverAuthorSourcesJob`, `FetchAuthorRSSJob`, `RSSLivenessJob`, `RefreshCostsJob`,
`DbtRefreshJob`, `CacheSweepJob`) staleness is genuinely the whole cost, and scaling to
zero is a defensible trade. The two remaining non-staleness cases can each be fixed the
same way the index was — by making them event-driven or read-time — which would remove the
need for an always-on machine altogether rather than paying for one.

**Recommended, revised:** don't add a worker machine yet. Add a read-time expiry check for
listings, and either accept unbounded unconfirmed-signup retention or trigger that erasure
from a request path. Then `min_machines_running = 0` costs only freshness, which is what
the owner said from the start.

## Original analysis (retained — the mechanism is still accurate)

**Found 2026-07-28 while investigating G3 ("why is `discovered_sources` empty after months of daily
cron?"). It is not a wiring gap. It is one infrastructure fact, and it explains most of ROOT G at once.**

`deploy/fly.core.toml`:

```toml
auto_stop_machines = true
auto_start_machines = true
min_machines_running = 0
```

Oban's `Cron` plugin fires **only while a node is running**, and it does **not** backfill missed windows
on boot. With zero machines running, a `{"0 8 * * *", …}` entry can never execute: the machine is asleep
at 08:00, and when an HTTP request wakes it at some other hour, the plugin schedules from *then* — the
missed window is simply gone.

**All twelve scheduled jobs are structurally unable to run:**

| Job | Schedule | Output table, measured |
|---|---|---|
| `DiscoverAuthorSourcesJob` | 08:00 daily | `discovered_sources` = **0** |
| `FetchAuthorRSSJob` | 07:00 daily | authors with `rss_feed_url` = **0** |
| `TriggerPriceScrapeJob` | 04:00 daily | `price_snapshots` = **0** (before this wave) |
| `RSSLivenessJob` | Sundays 03:00 | — |
| `ImageRetentionJob`, `RefreshCostsJob`, `ListingExpiryJob`, `DbtRefreshJob`, `CacheSweepJob`, `GuardianTokenSweepJob`, `ExpiredUnverifiedAccountsJob`, and now `BuildScraperIndexJob` | various | — |

**This reframes ROOT G.** Six items were diagnosed as individually "built but not wired". Several share
one cause: the wiring exists and the scheduler cannot run. `W-18`'s "no Oban job of any kind has ever
executed in staging" was the symptom — this is why. It also means **GDPR-adjacent** sweeps
(`ExpiredUnverifiedAccountsJob`, `ImageRetentionJob`'s 30-day retention, `GuardianTokenSweepJob`) have
never run either, which is a compliance exposure rather than a missing feature.

**Not fixed here, because it is a cost decision the owner has to make.** The options, cheapest first:

1. **`min_machines_running = 1`** on the core app — one always-warm machine. Simplest; costs one machine
   continuously.
2. **A separate worker process group** with `min_machines_running = 1` and no HTTP service, running only
   Oban. Keeps the web tier scaling to zero, pays for one small always-on worker, and has the side benefit
   of isolating background load from request handling (which the `Core.ObanRepo` pool split already aimed
   at).
3. **An external trigger** — a scheduled Fly Machine or an off-platform cron hitting a gated endpoint that
   enqueues the batch. Keeps zero-scale, adds a moving part and a new auth surface.

Option 2 is the one I would take: it matches the pool-isolation design already in `runtime.exs`, and it
keeps the cost to a single small machine rather than keeping the web tier warm.

⚠️ **Until this is decided, treat every "the pipeline produces nothing" finding as unproven rather than
fixed.** The price path in Wave 0d now works when *driven*, which is why the DoD could be met by hand —
but on the deployed stack it will still produce nothing until something can actually run it.

## 🟧 ROOT D — The documentation has drifted from the code, in both directions
**Leverage: medium-high — cheap, and it is what makes every other plan unreliable (the #119 class).**

10 unmapped story files (5 MVP + 2 extended + 3 stale component names); onboarding documented as
Welcome→**Upload**→Choose-shelf but built as Welcome→**Privacy**→Done (**W-3**); the vision cascade
documented as 4 stages but built as 2 (**W-16**) — and `notes/` Milestone E costs its savings against
"barcode → cover-embedding → OCR" tiers, **two of which do not exist**; `implementation-mapping.md:1857`
names three settings pages that were removed or consolidated.

## 🟧 ROOT E — The default state and first impressions are unfinished
**Leverage: high for launch (Milestone B is the promotion surface), individually cheap.**

**W-1** sign-in takes ~30s from a 200 OK with no feedback · **W-12** every book greyed out · **W-2** the
onboarding scrim hides the shelf it exists to showcase · **W-4** Skip never persists so the overlay
returns on every page forever · **W-9** the authenticated home is the marketing page with no route into
the user's own collection · **W-6** settings renders as an unstyled bulleted list with the mobile
`<select>` visible at **every** width (no breakpoint exists) · **W-15** **every** Open Library cover
fails to load because CSP allows `covers.openlibrary.org` but not its `archive.org` redirect target ·
**E5** Looking for a Home breaks the shelf family · three empty "Sentiment data coming soon" cards plus
an empty "AI-generated summary" on book detail.

## ⛔ ROOT G — Six capabilities are built but not connected. This is the dominant defect class.
**Leverage: highest per hour of the whole plan.** Found by completing the Wiring Trace sweep
(2026-07-27) — the stage the first synthesis skipped. Each of these is a **nearly-finished feature**,
not a bug: the expensive work is done and the value simply isn't collected.

| # | Capability | Built and paid for | Missing hop(s) | Story |
|---|---|---|---|---|
| G1 | **Third spaces** | complete Elm page (171 LOC, own decoders), live `GET /api/third-spaces`, context fn | **triple break** — page has no route and is never imported; **`third_spaces` = 0 and `third_space_events` = 0**, so the endpoint returns empty regardless | US-3.1.1 |
| G2 | **Prices** | Rust scraper built + deployed, 2 TOML targets, cron `0 4 * * *` + event-chained, `PriceInfo.elm` (149 LOC) | **both ends** — `op.bookstores` = 0 so the job is a no-op returning `:ok`; and no read endpoint, so `PriceInfo` gets `NotAsked`. `price_snapshots` = 0 ever | US-2.2.1 |
| G3 | **Source discovery** | `DiscoverAuthorSourcesJob` cron `0 8 * * *`, `SourceDiscoveryJob`/`ScoreSourceJob` chained, live `/admin/sources` approve/reject UI | **`discovered_sources` = 0** — not one source has ever been discovered, so the admin UI has never had a row to approve | US-2.5.1 |
| G4 | **RSS / Atom feeds** | `RegenerateFeedJob` event-chained from `placement_handler:53`, live `GET /api/feeds/:user_id/:bookshelf_name`, **and an `rss.spec.ts` E2E** | **`feed_cache` = 0** and **no client call** — `/feeds` is built nowhere in the Elm tree | US-6.1.1 |
| G5 | **Shelf organisation** | 35 backend tests (`shelf_controller_test` 18 + `shelving_shelf_test` 17), full CRUD + reorder controller | **no client call for the `/shelves` sub-resource**; `Api.elm:831` builds only the bookshelf GET. No create/delete/reorder UI | US-1.7.1 (#190) |
| G6 | **Business opt-out** | live `POST /api/opt-out` + `OptOutController` | **no client call anywhere in Elm** | US-2.5.3 |

### The systemic cause behind G4 — and a warning for every event-driven feature
**`event_log` has 12 rows** against 222 placements and 170 books, because `seeds.exs` uses `insert_all`
and **bypasses `Events.emit/1`**. So seeded placements emit nothing, `RegenerateFeedJob` never fires,
and `feed_cache` stays empty. **Every feature downstream of the event bus is therefore unexercised in
staging**, whatever its unit tests say — the EDA spine has effectively never run there. Any future
"is this wired?" question about an event subscriber has the same answer until seeds emit events.

### Corrected: one former instance is fixed
`notes/phase-1-launch-extension.md:16-20` cites reading-progress as orphaned ("`PlacementCard` mounted
nowhere"). **That is now stale** — it is mounted at `BookDetail.elm:991` and `ReadingPile.elm:329`. One
fewer break, and a `notes/` line to correct in Wave 7.

### Instrument caveat — record this, it cost three iterations
Grep-based set-differences are **unreliable in both directions** and must be corroborated:
- **40 false positives** from matching whole paths (Api.elm concatenates: `baseUrl ++ "/api/bookshelves/" ++ name ++ "/placements"`).
- **A false negative** from matching bare segments (`/bookshelves/:name/shelves` passed because the word
  "shelves" appears in `shelvesResponseDecoder`).
- **4 more false positives** from missing `Url.Builder.absolute [ "api", "catalogue" ]` — paths built
  from **segment lists**, not string literals.

**Trustworthy pair:** the **zero-row sweep** (clean and decisive first time) plus the **live network
trace** from the walkthrough. Use grep only to *generate hints*, then confirm each against the actual
`url =` construction site. Also found: `/costs` is fetched directly in `Page/CostTransparency.elm:118`
rather than through `Api.elm` — a 🟨 two-ways-to-do-it, the HTTP layer bypassed.

### Wave 0b — Wire what is already built (insert immediately after Wave 0)
**Why this early:** six nearly-finished features, each one hop from working, several belonging to
stories currently believed done. Highest value-per-hour in the plan, and it shrinks ROOT D's drift too.
| Issue | Root | Size |
|---|---|---|
| **G2 prices, one target end to end** — ⚠️ **rescoped by D4–D8**, see Wave 0d. Not "seed + one scrape": the fetch path is rewritten first. Still *one* target proven end to end before any others (`exclusivebooks`, the only store with direct `/products/<isbn>.js` lookup) | G/#117 | **L** |
| **G5 shelf organisation UI** (#190) — wire `/shelves` create/delete/reorder/move. ✅ **Decided: build both** drag-and-drop *and* explicit controls (accessibility + intuitiveness). Split by action, not by one issue doing both | G/#190 | M→L |
| **G4 RSS feeds** — ✅ **server side DONE and proven (2026-07-28):** `feed_cache` **0 → 4 rows** with 32/19/4/3 entries. Remaining: the Elm client call, plus two conformance holes filed separately | G | S |
| **G6 business opt-out** — ✅ **Decided: standalone submission form** with a contact address, domain-verified. **Server side is done** (see below); the remaining work is the form and the `third_space` removal path | G | M |
| **G3 source discovery** — establish why `discovered_sources` is empty after months of daily cron: no seed authors, a silent failure, or never actually scheduled in staging | G | S |
| **G1 third spaces** — ⚠️ **removed from Wave 0b.** Specified but **not** promotable — see below | G | — |

⚠️ **Every G-item needs the zero-row check as its DoD evidence**, not a passing test: *the output table
has ≥1 row in a real environment, and the value renders.* That is the only proof that distinguishes
these from their current state.

#### Wave 0b resolution — 2026-07-28 (supersedes `plans/wave-0b-remaining-spec-2026-07-28.md`)

The four remaining G-items were specified in full. **They turned out to be four different problems, and
only two of them were the wiring task the table implied.**

| | Filed as | Actually is | Now |
|---|---|---|---|
| **G5** | frontend wiring | ✅ exactly that — backend complete, `issues/190` already specifies it | **In Wave 0b.** Scope grew (both affordances) but the shape held |
| **G4** | wire `/feeds` + seeds emit events | 🟡 **the product path already works** — it is a *fixture* gap | **In Wave 0b, smaller than filed**, plus two real conformance bugs |
| **G6** | add a surface for `POST /api/opt-out` | 🟠 server done; entry point depended on a surface that does not exist | **In Wave 0b, decoupled from G1** |
| **G1** | route the page + seed data | 🔴 **no story existed, and nothing can produce the data.** A Phase 4 story in a Phase 1 wave | **Out of Wave 0b.** Story now written and decided; work sequenced later |

**G5 — both affordances, and the reason it is not scope creep.** Drag-and-drop needs a keyboard path
regardless, so "drag only" was never actually cheaper than "both" — it was the same work with the
accessible half deferred until an audit forced it. Explicit controls *are* that keyboard path. Split the
issue by **action** (create/delete, then reorder/move) rather than by affordance, so each ships with both
input methods and neither is left half-accessible.

**G4 — the fixture gap, and two conformance bugs found while specifying it.** `feed_cache` = 0 not
because the feature is broken but because `seeds.exs` uses 14 `insert_all` calls and **0** `Events.emit`
calls, so `RegenerateFeedJob` never fires for seeded data — the same systemic cause as G3. Making seeds
emit events is the general fix and is worth more than the feed itself. Two genuine bugs surfaced
alongside it, both now fixed:
- entries said "added" for books that were **moved** between bookshelves (`moved_book_ids/2`)
- covers were absent — no `<link rel="enclosure">`, so no feed reader could show a book cover

⚠️ **Two conformance holes remain open and are new issues, not Wave 0b scope:** the feed has **no
`<link rel="self">`** (RFC 4287 requires it; validators flag it) and **no per-entry link**, so a reader
cannot click from their feed reader to the book. This is also why the reported "RSS will use the wrong
host" concern is *not* real — the feed uses `urn:stacks:` IDs and contains no absolute self-links at
all. That is the deeper defect: the host is not wrong, the links are missing.

##### ✅ G4 server side landed and proven, 2026-07-28

`seeds.exs` now replays `placement.created` for every seeded placement, driven off the rows that
actually landed (a join against `bookshelf_placements`) rather than the in-memory lists — so it covers
every `insert_all` site including the E2E users, and cannot drift from them.

**The zero-row check, run against the DB that `test-dbt` had just seeded from scratch:**

| Table / queue | Before | After |
|---|---|---|
| `op.event_log` where `placement.created` | 0 | **220** |
| `oban_jobs` SubscriberWorker | 0 | 220 |
| `oban_jobs` RegenerateFeedJob | 0 | 220 |
| **`op.feed_cache`** | **0 — in every environment, ever** | **4** |

The four rows are real feeds, not empty shells: `antilibrary` 13,151 bytes / 32 entries, `library`
7,601 / 19, `reading_pile` 1,854 / 4, and the E2E user's `library` 1,507 / 3 — four distinct etags.
Exactly four because only platform-visible bookshelves get a feed, which is the designed behaviour.

**A new test class was added, and it is the transferable part.**
`apps/core/test/stacks/feeds/placement_to_feed_cache_chain_test.exs` drives the *whole* chain through
the real Oban queues (`Oban.drain_queue/2`, not `perform_job/2`):

    emit placement.created → SubscriberWorker → PlacementHandler → RegenerateFeedJob → feed_cache row

⚠️ **The probe that justifies it:** unregistering `PlacementHandler` from `"placement.created"` in the
event registry — *the exact production defect* — leaves **all 23 existing unit tests green** and fails
only the two positive chain tests. The handler test passes because it calls the handler directly; the
job test passes because it performs the job directly. Neither can see a missing wire. **This is the
instrument ROOT G was missing**, and every other event-driven feature deserves the same shape.

**One thing deliberately NOT done.** I added `unique:` to `RegenerateFeedJob` to collapse the 220
duplicate regenerations, then reverted it. Oban warns that unique `states` omitting `:executing` "may
break uniqueness", and the obvious fix — adding `:executing` — introduces a **lost update**: a
regeneration already in flight may have read the placements before the newest one committed, so
collapsing the new event into it drops that book from the feed. The correct `states` therefore emit a
permanent build warning that invites exactly that wrong fix. Since the plan asked for the fixture gap
and not for dedup, the waste (idempotent, upserts one row per bookshelf) stays, with the analysis
written into the worker's comments so the trap is not rediscovered. Filed as a performance follow-up,
not a defect.

**G6 — server-side complete as of 2026-07-28 (`a435e2b2`).** Decided: a standalone submission form
carrying a contact address, verified by matching the requester's email domain against the listing's
domain. Built and merged: `Discovery.record_removal_request/2`, `email_domain_matches_source?/2`
(handles `www.`, deep paths, subdomains, and multi-part suffixes like `.co.za`), a new
`exclusion_requested_at` proto field, and a pending state derived from it. A domain match auto-excludes;
anything else parks for owner review. **Remaining in Wave 0b:** the form UI, the owner review queue, and
extending the verified path to the `third_space` row (soft-delete via the existing
`opted_out`/`opted_out_at` — a hard delete would be rediscovered and re-listed, see US-3.1.1 §8).

**G1 — specified, decided, and deliberately not promoted.** `docs/user_stories/US-3.1.1-third-spaces-map.md`
now exists (it was referenced by `implementation-mapping.md` but had no file, so it could not be built to
spec) and all six of its open decisions are resolved: reader-facing category filters; owner-curated
"well-regarded" with no stars or scores anywhere; `third_space` created **only** by source approval; one
narrow Elm port (camera/pins out, viewport/click in — the project's first, and the precedent); hosted
tiles **proxied through our backend** so no reader IP or viewport reaches a third party; and plain
lat/lng columns with a bounding-box query rather than PostGIS.

⚠️ **Specifying it did not make it Phase 1 work.** Three of its four data inputs do not exist: no
producer for `third_spaces`, **no lat/lng on either `op.third_spaces` or `op.bookstores`** (so the 500 m
rule cannot be computed at all), no events, no rating source. Routing the finished Elm page to the main
navigation would put a permanently empty map on the nav — worse than leaving it unrouted, because it
promises something. **The route lands only when the data does.**

Two findings worth keeping from that specification pass:
- `Stacks.Enrichment.haversine_km/4` is already written and working (`enrichment.ex:244`); it is useless
  only because `within_radius?/4` joins against a hardcoded **six-entry** `@city_coords` map. Adding the
  columns makes existing code correct rather than adding new code.
- The 500 m proximity join must be **precomputed at geocode time**, not per-request. Recomputing it
  across every space in a viewport on every pan is exactly the query that would later force PostGIS for
  the wrong reason.

### Wave 0c — ⛔ Compliance: make the robots.txt hard rule structural (before any scrape runs)
**Why before Wave 0d:** no new scraping may be built on a layer that only approximates the rule.

⚠️ **Urgency corrected.** An earlier draft said one violation was "live in a cron." **It is not** — the
full `crontab` in `config.exs` does not contain `DiscoverBookstoreEventsJob`, and it has no enqueue site.
Nothing is being scraped non-compliantly today. These are **latent** violations that must be fixed
*before* D7 wires the job up.

| Issue | What | Ladder climb | Status |
|---|---|---|---|
| **C1** | **Delete `respect_robots_txt`.** A hard rule a config file can switch off is not a hard rule (was `config.rs:67`, read at `scraper.rs:91`). Test fixtures used it to avoid the network; they now use the `mock` seam already checked alongside it, so no coverage was lost | Rung 1: **impossible by construction** — the flag no longer exists | ✅ **DONE** |
| **C2** | **Honour `Crawl-delay`**, previously *intentionally* ignored. `RobotsChecker` now returns a `RobotsPolicy { allowed, crawl_delay_secs }` and the engine takes `min(robots_rpm, configured_rpm)`, so a declared delay wins **whenever it is stricter**. Exclusive Books declares 10s = 6 req/min against a TOML asking for 10 | Rung 3: the stricter bound is enforced, not advisory | ✅ **DONE** |
| **C5** | **Distinguish 4xx from 5xx.** The old `is_allowed` treated *any* fetch failure as permission. Now: 2xx→parse, 4xx→allow-all (§2.3.1.3), **5xx/transport→`RobotsFetchFailed`, i.e. stop** (§2.3.1.4). Extracted as a pure `classify_status/1` so the distinction is testable without a network. Deliberately **not cached** — `get_or_try_init` doesn't store on `Err`, so a transient 503 blocks one attempt rather than poisoning the domain | Correctness against the spec we claim to implement | ✅ **DONE** |
| **C6** | 🆕 **A site could not address us by name.** Matching compared robots.txt agent tokens against the *full* UA header (`TheStacksScraper/0.1 (+https://…)`), which no operator would ever write — so only `User-agent: *` ever matched and a shop that specifically blocked us was **silently ignored**. Now matches the bare product token, with §2.2.1 group selection (a named group beats the wildcard group, and only the winning group's rules apply) | Removes a silent non-compliance | ✅ **DONE** |
| **C7** | 🆕 **Wildcard rules never matched.** `starts_with(prefix)` treated `*` literally, so `Disallow: /collections/*sort_by*` matched nothing and we would have scraped it believing we were compliant. Implemented §2.2.3 `*`/`$` matching | Removes a second silent non-compliance | ✅ **DONE** |
| **C8** | 🆕 **Rate limiter ran *before* the robots check**, spending a rate-limit slot on a request we then refused to make — so a disallowed store could exhaust its own budget without reaching the network. Order reversed, which is also the only order in which the returned `Crawl-delay` can inform the rate decision | Ordering correctness | ✅ **DONE** |
| **C3** | **`DiscoverBookstoreEventsJob` performs no robots.txt check** — bare `Finch.build(:get, "#{website_url}/events")` (`:68-74`), no rate limiter, no fuse. Per **D7** route it through the compliant egress. **Blocked on that egress existing** → moved into Wave 0d | Removes an entire unguarded egress path | → **0d** |
| **C4** | **`robots_blocked` becomes a store state** — `{blocked_path, matching_rule, observed_at}`, re-checked on the probe cadence, resuming by itself if the disallow lifts. Owner: *config stays in place*. Needs the proto schema change → Wave 0d | Rung 5: observable state instead of a silent skip | → **0d** |

**Evidence for C1/C2/C5/C6/C7/C8:** 65 unit + 7 integration tests green, and **three mutation probes**
run and reverted, each failing on exactly the assertion that encodes the rule:
- product token → full UA string: `test_a_site_can_address_us_by_our_product_token` and
  `test_named_group_wins_even_when_it_is_more_permissive` both FAILED ("a group naming our product token
  must win over the wildcard group").
- §2.2.3 matching → literal `starts_with`: `test_wildcard_and_anchor_patterns` FAILED on
  `!apply(robots, "/collections/all?sort_by=price").allowed` — i.e. a disallowed path reported allowed.
- `classify_status` → any-non-2xx-means-allow: `test_status_classification…` FAILED
  (`left: NoRestrictions, right: Unreachable`) — **and clippy caught it first**, because the mutation makes
  `StatusVerdict::Unreachable` unconstructible. That is the rule being enforced at rung 3 rather than
  rung 6, which is a better outcome than the test.

**Remaining DoD (in 0d):** a probe against `exclusivebooks.co.za/search` must record a `robots_blocked`
state and **stop**, with the store's configuration still present.

### Wave 0d — ⛔ Rebuild the price fetch path on the capability probe (replaces "write 11 TOMLs")
**Why here:** this is the *prerequisite* for Wave 0b's G2, not a parallel track. Sequenced after 0c so
nothing scrapes before the rule is structural. Full design and evidence:
`plans/scraper-architecture-research-2026-07-27.md`.

| Issue | What | Size |
|---|---|---|
| **P1** | ✅ **DONE** — **Re-keyed `price_snapshots` to `book_edition_id`** (D5) while the table was empty. See the completion note below | **S→M** |
| **P2** | ✅ **DONE** — **Typed outcomes.** Turned out to be a prerequisite for the feature working at all, not a tidiness item; see the note below | **S→M** |
| **P3** | 🟡 **MOSTLY DONE** — detection built and wired (`Engine::detect_capability` + `capability_for`), reported on every scrape response, and **persisted** on `op.bookstores` with `capability_probed_at`. **Still to do:** the **canary assertion** (column exists, nothing writes or checks it) and deleting the `scraper_module` string coupling | **M** |
| **P4** | ✅ **DONE** — **Two platform adapters** built, wired, and verified against live payloads. See the note below. TOML field deletion (`[selectors]`, `search.*`, and the four parsed-but-never-read fields) remains, sequenced after the legacy path stops being the fallback for anyone | **M** |
| **P5** | ✅ **DONE** — ISBN ladder complete, including the fuzzy rung for `ikesbooks`/`lovebooks`. Reuses `CandidateScorer`, but **not blindly** — see the note below | **M** |
| **P6** | ✅ **DONE** — **lazy prices with a staleness TTL** (D8), plus the read endpoint and the Elm wiring that finally closes the W-18 chain. See the note below | **M** |
| **P7** | **Edition discovery from Open Library** — work → editions (verified: 151 editions / 76 ISBN-13s for one seed). ⚠️ **must be capped** before reaching the price layer: 76 × 8 stores = 608 requests per work. Reuses `ISBNResolver`'s cache + fuses | **M** |
| **P8** | 🟡 **MOSTLY DONE** — pointer-only index built and proven live: **Wordsworth prices R215.00 for "Where's Spot?"** at `/products/wheres-spot-2`, a handle nothing like its ISBN. 3,924 entries swept. **Remaining:** the index is in-process and dies on restart, so an Oban job must call `POST /index/build` on a cadence | **M** |
| **P9** | **Record the four unscrapable targets as `:none` with a reason** (`loot`, `fortunatefinds`, `ikesbooks`, `lovebooks`) rather than configuring them hopefully. Re-probe `kalkbaybooks` (503) and `skoobs` (connection error) | **S** |
| **P10** | ✅ **DONE** — **per-store fuses**, no longer deferred. See the note below | **S→M** |

**Cross-cutting for any LLM tier here** (events, or the residual matcher): never raw HTML (Markdown or
JSON-LD-subset pruning first — 80–90% token reduction), strict output schema, built on
`TogetherClient.complete/2`, and routed through `BudgetTracker` — which today is wired to **vision only**;
`TogetherClient` and `ScraperClient` bypass it entirely. Gated on `mix eval.*` corpus discipline, the same
bar `notes/phase-portfolio-plan.md:17-22` holds the vision work to.

**DoD for the wave: ✅ MET (2026-07-28).** Driven against a locally-running scraper service and the **live**
Exclusive Books site:

| Check | Result |
|---|---|
| `price_snapshots` row count | **0 → 1** (the zero-row sweep, satisfied) |
| Read model (`GET /api/books/:id/prices`) | `9780749397050 · Exclusive Books · 40000 ZAR · in_stock=true`, correct product URL |
| Keyed by edition | ✅ `book_edition_id`, not `book_id` |
| `NOT_STOCKED` distinct | ✅ `9780156001311` → outcome `NOT_STOCKED`, detail *"does not stock ISBN…"*, and **no row written** |
| Capability derived + persisted | ✅ `nil → shopify_products_json / handle / direct`, `probed_at` stamped, change logged |

**Four defects the drive found that no test had.** This is why the Evidence Standard requires running it:

1. ⛔ **`scraper_module` matched nothing, for every seeded store.** The Rust registry keys configs by path
   (`za/exclusive_books`); the seed carried the bare basename. Result: `404 store not found` forever, the
   job reporting failure, and no price ever. It had been that way since the seed was written. Fixed, plus
   a guard that catches exactly that mistake (a value matching a config's *basename* but not its full key)
   and, in the other direction, a config no store references — which immediately found `za/takealot`, not
   on the owner's list and using the abandoned selector design, now deleted.
2. 🟧 **The Exclusive Books TOML still pointed at `www`**, which 301s. I had corrected the seed but not the
   config, so every request would have cost two round trips.
3. 🟨 **A stray `python3.1` process held IPv4 `*:8080`** from an earlier session while our service bound
   IPv6, so `localhost` resolved to the wrong service — which answered `{"detail":"Not Found"}`, FastAPI's
   format rather than ours. Worth knowing as a debugging tell; the shape of the error body identified the
   wrong process faster than anything else.
4. 🟨 The first probe run also confirmed the **401 → service fuse** classification from P10 behaving
   correctly when the HMAC secret differed (`.env` supplies a real one; `config.exs`'s dev default is not
   what runs).

#### Two further defects found only by driving it, after the DoD was met

Both appeared only under a **real rate limit**, which no test reproduced:

1. ⛔ **A failed capability probe was recorded as "this store has no product API."**
   `capability_for/2` folded any detection error into `Capability::none()` and cached it. Under Wordsworth's
   10 req/min limit that happened immediately, and the consequences cascaded: the scrape routed to the
   abandoned CSS-selector path, produced a price-parse error against HTML (`cannot parse 'Original price\n
   R 215.00…'`), melted that store's fuse, and persisted `price_source: "none"` for a shop with a working
   Shopify API. *"We could not observe"* and *"we observed nothing"* are different claims and only the
   second is worth recording — detection failures now propagate instead.
2. 🟧 **Building an index inline in a price request cannot work.** A sweep is up to 20 requests against a
   shop limited to ten a minute; the limiter correctly refused, so the first lookup failed rather than
   waiting. Build is now a separate operation (`POST /index/build`) that *waits* on the limiter, while a
   price lookup still surfaces the limit rather than holding a request open for minutes.

**Still open in the wave:** **P5** (fuzzy title matching for `ikesbooks`/`lovebooks`, which carry no ISBN
at all — needs `CandidateScorer` plus an eval corpus, and it must run Elixir-side because the scraper does
not know our catalogue), and **P8's remainder**: the index lives in-process and dies on restart, so an Oban
job must call `POST /index/build` on a cadence.

#### P6 completion note — the W-18 chain is closed, and the nightly sweep is gone

W-18 found a chain with **no data at either end**: `latest_prices/1` had no production caller (tests
only), and `PriceInfo.view NotAsked` was hardcoded. Both ends now exist.

**The read path replaces the sweep.** `Prices.prices_for_work/2` returns what is stored and enqueues a
refresh for anything past the TTL. The old nightly batch was `stale_isbns(7) × all_stores()` with no cap —
~2,400 requests over ~20 hours against eleven mostly one-person shops, for prices nobody may look at.
Outbound load now tracks reader interest. Reads return immediately with stale data rather than blocking: a
week-old price beats a spinner, and Oban `unique: [period: 3600]` stops a popular book enqueueing a scrape
per page view.

`GET /api/books/:id/prices` returns one row per **(edition, store)** carrying ISBN, format and store name.
Exposing only the work would show one arbitrary price as though it were the price of the book.

**Two test-harness findings, both worth keeping:**
- 🟧 **`TestHelpers` keeps a parallel list of simulated init effects.** A page that gains a request makes
  **none** in ProgramTests until it is added there separately — a second source of truth that drifts
  silently. It cost a confusing failure here (`no such requests were made`). The new effect reuses
  `BookDetail.pricesDecoder` rather than hand-mirroring it, which is what `decodeAvailabilityResponse`
  does — that copy can diverge from production without any test noticing.
- 🟨 **A test was asserting the absence of the feature.** `section_content` asserted
  `text "No price data yet"`, which passed precisely because the page fetched nothing. It now simulates an
  empty response for that case, and a new `pricesRenderPerEdition` proves prices actually render — both
  ISBNs, the store name, and no placeholder.

**Evidence:** 2,986 Elixir tests, 1,180 Elm tests, 240 dbt tests, `just verify` exit 0. Mutation probes:
inverting the TTL comparison fails both freshness tests in opposite directions; collapsing
`groupPricesByEdition` to one edition fails the distinctness and rand-conversion tests; restoring
`PriceInfo.view NotAsked` fails `pricesRenderPerEdition`.

**Not yet done:** no price has flowed end to end from a live shop into the page — that needs the Elixir
capability persistence (P3's remainder) and a preview stack. The Wave 0d DoD is not met until it has.

#### P5 completion note — reusing the scorer was right, reusing it *alone* was not

The plan said reuse `CandidateScorer` rather than write a second matcher. That was
correct and it earns its place: measured against a "The Name of the Rose" signal, a
derivative (*"A Study Guide to The Name of the Rose"*) scores **1.0** against the real
book's **3.5**, and unrelated titles score **0.0**. The derivative penalty and the
plausibility floor do real work.

**But measuring showed the scorer alone is unsafe here, and my first thresholds were
guesses that were simply wrong.** I set a floor of 4.0; the correct match scores 3.5, so
nothing would ever have matched. Worse, the title signal is an **overlap coefficient** —
intersection over the *smaller* token set — so any subset scores full marks:

| Score | Case |
|---|---|
| 3.5 | exact title |
| 3.0 | `"The Island"` vs `"The Island of the Day Before"` |
| 3.0 | `"Sapiens"` vs `"Sapiens: A Brief History of Humankind"` |
| 1.0 | derivative (study guide) |
| 0.0 | unrelated |

Only **0.5** separates an exact match from a partial one. That behaviour is *right* for
the resolver, which wants a subtitled edition to match its work — and wrong on a shop's
shelf, where extra words often mean a different volume or a boxed set.

**So a token-symmetry requirement (Jaccard) sits on top of the score.** Jaccard punishes
the asymmetry overlap ignores: 1.0 exact, 0.33 for the Island pair, 0.17 for the Sapiens
pair. It refuses some legitimate matches, deliberately: for a shop with no ISBNs, no
price is honest and someone else's price — attached to a buy link — is not. The stakes
differ from the resolver's, so the bar does too: a wrong ISBN match shows wrong metadata;
a wrong *store* match sells the reader the wrong book.

Also required: the winner must beat the runner-up by a margin, so two near-identical
listings refuse rather than guess. **Mutation probe:** removing the symmetry gate fails
both partial-title tests; the margin test has a companion proving it is *ambiguity* and
not the floor doing the refusing.

**Wiring** (checked, since this is the dominant defect class): `product_path` added to
`ScrapeRequest` so the caller can say where to look — necessary because the service knows
the shop while only we know our catalogue. A weekly job fetches titles, matches, and
spends each match immediately on a price fetch through the existing pipeline. **No pointer
table**: persisting matches would add a third thing to keep fresh, invalidated by
re-slugging, catalogue changes, and threshold retuning — for two shops with a price TTL
already in place, make-and-spend is the smaller design.

#### P4 completion note — the adapters, verified against live shops

Two adapters in `apps/scraper/src/platform.rs`, all parsing as pure functions over a JSON string so the
traps below are testable without a network.

**The trap that would have been a silent 100× error.** Shopify's two endpoints represent the *same price*
differently: `/products/<handle>.js` returns **integer cents** (`40000`), while `/products.json` returns a
**decimal string** (`"400.00"`). WooCommerce returns a **string of minor units** (`"24500"`). They get
separate functions rather than a shared "parse a Shopify price" helper, and the `.js` parser **refuses any
string price outright** rather than guessing the unit.

⚠️ **My first test for that was vacuous and the mutation probe caught it.** It asserted `"400.00"` is
refused — but `"400.00"` fails an integer parse anyway, so a permissive implementation rejects it too. The
discriminating input is a *numeric* string (`"40000"`), which a permissive parser happily accepts as cents.
Rewritten, the probe then failed correctly: `price "40000" should have been refused`.

**A second bug my own test caught.** `is_isbn13` stripped separators before comparing, so the handle
`"some-title-9781049281483-paperback"` normalised to exactly those digits and looked directly addressable
by ISBN — which is precisely the 404 measured at Bridge Books. Split into `is_exact_isbn13` (no stripping,
for deciding whether a URL segment *is* an ISBN) and `normalise_isbn` (stripping, for comparing SKU
*values*, which are legitimately hyphenated). `handle_is_isbn_ratio` also requires ≥0.9 of a sample rather
than a single hit, because Bridge Books has an ISBN inside 37/50 handles without the handle being one.

**Wiring — checked, because "built but not wired" is the dominant defect class here.** After building the
adapters I grepped for a caller and found none: the handler still called `Engine::scrape` (the selector
path), so `platform.rs` was a seventh instance in the making. It now routes through `scrape_auto`, which
picks the mechanism from the *observed* capability and falls back to CSS selectors **only** where no
product API exists at all — deliberately not for Shopify stores, whose search cannot match an ISBN in any
field, so a fallback there would only burn requests.

`ScraperError::NotStocked` and `IndexRequired` were added, which is what finally makes P2's
`SCRAPE_OUTCOME_NOT_STOCKED` reachable — nothing could emit it before. The exhaustive match in
`outcome_for_error/1` **forced** both to be classified rather than defaulting to "failure", exactly as
that design intended. `IndexRequired` maps to `EXTRACTOR_FAILED`, never `NOT_STOCKED`: we do not know
whether the shop carries the book, only that we cannot ask, and recording a guess would write false
negatives as though they were facts about stock.

Also extracted `fetch_path` as the **single compliant egress** — robots.txt, then rate limit, then fetch —
shared by both the legacy and adapter paths, and returning the HTTP status because for adapters **404 is
data**, not an error. That is also the seam C3 needs to route the events job through. The crawl-delay
computation, which I had duplicated, is now one `effective_rpm/2`.

**Live verification** (payloads captured from the real shops, `Crawl-delay: 10` honoured between requests):

| Store | Request | Result |
|---|---|---|
| exclusivebooks | `/products/9780749397050.js` | **200** → 40000 cents = R400.00, `in_stock=true`, title "Name of the Rose" |
| exclusivebooks | `/products/9780156001311.js` | **404** → `NotStocked` reachable, as measured |
| booklounge | Store API `?search=9780008717360` | **200** → 24500 cents = R245.00, "Crow: Thief of Magic" |
| wordsworth | `/products.json?limit=50` | **200** → 50/50 prices parsed, 42/50 ISBNs extractable, classified `Sku` / `LocalIndex` |

**Evidence:** 84 unit + 12 integration Rust tests. Three mutation probes (price-unit strictness, the handle
bug, and — earlier — the outcome classifier), each reverted.

#### P2 completion note — ⛔ typed outcomes are a prerequisite, and Wave 0c created the urgency

Filed as "the highest-value ladder climb". Implementing it exposed that it is a **hard prerequisite for
prices working at all**, and that Wave 0c's robots.txt fix had just made the problem live:

**The interaction.** Every scrape error became an HTTP **500** (`main.rs`, one catch-all `Err(e)` arm), and
`ScraperClient` calls `CircuitBreakers.melt(:scraper_fuse)` on **any** non-200
(`scraper_client.ex:96,109`). `:scraper_fuse` is **3 failures / 60s → open 15 minutes** and is **shared by
every store** — per-store fuses are explicitly deferred (`circuit_breakers.ex:21`). So:

- Wave 0c made a robots.txt disallow correctly **stop** the scrape. That stop surfaced as a 500, so
  **3 attempts against a permanently-disallowed store opened the breaker for all twelve stores** — and
  because the condition recurs on every attempt, it would reopen forever. Exclusive Books disallows
  `/search`, which is exactly what the current config requests.
- The same applies to "not stocked" once the adapter lands, and worse: with per-edition pricing **most
  (edition, store) pairs legitimately have no price**, so the breaker would never close and the feature
  would be permanently dead.

**The fix — separate what the service *did* from what the scrape *concluded*.** `ScrapeOutcome` added to
`scraper.proto` (`PRICED` / `NOT_STOCKED` / `ROBOTS_BLOCKED` / `EXTRACTOR_FAILED`, plus `detail`).
Determinations return **200** carrying the outcome; only genuine service or network faults return 5xx.
The 200-vs-5xx decision lives in **one** function, `outcome_for_error/1`, which enumerates every
`ScraperError` variant explicitly rather than using a wildcard — so adding a variant forces a decision
instead of silently defaulting to "failure".

On the Elixir side `TriggerPriceScrapeJob.interpret/2` maps outcomes to
`{:ok, price}` / `{:determined, :not_stocked}` / `{:determined, :robots_blocked}` /
`{:error, :extractor_failed}`. Determinations do not count toward `evaluate_outcome/1` and record
`Monitoring.record_success` (the source answered correctly); extractor failures record
`Monitoring.record_failure`, which puts a per-store extraction bug in per-source health where it belongs
rather than in a service-wide breaker.

**Fail safe, not open:** an absent or unrecognised outcome is treated as a **failure**. A response that
cannot say what it concluded is not evidence that nothing went wrong, and this also catches a scraper
deployed older than the contract. Confirmed by the pre-existing tests, which all failed with
`unrecognised outcome nil` until their fixtures declared one.

**Evidence:** Rust 65 + 10 tests; Elixir job suite 13 tests. **Two mutation probes**, each reverted:
classifying `RobotsDisallowed` as a failure fails `robots_disallow_is_a_determination_not_a_failure`
(`left: None, right: Some("SCRAPE_OUTCOME_ROBOTS_BLOCKED")`) — **and clippy catches it first**, since
`ROBOTS_BLOCKED` becomes unconstructible; and returning `{:error, :robots_blocked}` from `interpret/2`
fails *"a robots.txt block is not a failure"* (`left: :ok, right: {:error, "all scrape requests failed"}`).

#### P10 completion note — two failure domains, two fuses

Owner ruling: *"we shouldn't defer the fix."* P2 stopped *determinations* from melting the shared fuse,
but a genuinely broken store still took down all twelve. The split P2 introduced is exactly what makes the
fix precise, because there are two domains and they were being conflated:

| Domain | Fuse | Melted by |
|---|---|---|
| The **sidecar** is unreachable or rejecting us | `:scraper_fuse` (shared — correctly, since no store is scrapeable) | transport failure, HTTP **401** (a bad HMAC is bad for every store) |
| **This shop** is failing | `:scraper_store_fuse_<store>` | any other non-200 (upstream HTTP error, rate limit, missing/invalid config) and a `SCRAPE_OUTCOME_EXTRACTOR_FAILED` 200 |

Both are consulted before every request; either open yields `{:error, :circuit_open}`. Note how the
non-200 cases redistribute: after P2 the sidecar only returns 5xx for `RateLimitExceeded`, upstream
`Http`, `RobotsFetchFailed`, `InvalidConfig`, `ConfigNotFound` — **all store-specific**. Melting the
shared fuse for those is precisely what let one shop stop the rest.

**Atom exhaustion made impossible, not merely unlikely.** `:fuse` keys circuits by atom and atoms are
never collected, so deriving one per store is an unbounded-growth vector — store rows are
operator-supplied and can be added at runtime. `store_fuse/1` resolves via `String.to_existing_atom`
first and only mints a new atom while below `@max_store_fuses` (256, versus twelve seeded); past the cap
it falls back to the shared fuse with a warning. Degraded isolation beats a node that cannot allocate
atoms.

**Store fuses are deliberately not probed.** The probe loop retries every 15s until a service answers,
but the only way to probe a bookshop is to make a request to it — which is what the open circuit exists
to prevent. `do_probe/2` now returns without rescheduling on `{:error, :no_probe}`, so store fuses recover
on the `{:reset, Ms}` backstop instead of logging 60 times per outage. The "no probe configured" log also
dropped from warning to debug, since for these it is the designed state rather than a misconfiguration.

**Evidence:** 112 tests across the circuit-breaker, enrichment and job suites. **Mutation probe:**
collapsing `store_fuse/1` back to `:scraper_fuse` fails *"one failing store does not open the circuit for
another"* on `each store must get its own circuit`.

#### P1 completion note — the wrong grain was not cosmetic, it was a live silent defect

The re-key was filed as tidiness (D3 consistency). Implementing it surfaced a **correctness bug that was
already shipping**, plus two downstream instances of the same root that the plan had not listed:

1. ⛔ **`stale_isbns/1` made most editions unpriceable.** It left-joined snapshots to editions on
   `book_id`, so a fresh price for **one** edition marked **every** edition of that work as freshly
   scraped. On a work with six editions, five could never be selected for pricing — ever. Now joined on
   `book_edition_id`. Covered by *"staleness is per edition: pricing one leaves its siblings stale"*;
   **mutation probe:** restoring the `book_id` join fails that test on
   `"a sibling edition was never priced and must still be stale"`, and fails a second test too.
2. 🟧 **`int_price_trends` partitioned `row_number()` by `(book_id, store_id)`.** With several editions
   at one store, `recency_rank = 1` kept whichever edition was scraped last and the rest **vanished from
   `mart_book_prices`**. Now partitioned by `(book_edition_id, store_id)`, and the mart carries
   `book_edition_id` + `isbn` so editions are distinguishable at all.
3. 🟨 **`dbt/models/staging/sources.yml` did not declare the new column** — the class of gap
   `mix test` cannot see and only `just verify` catches.

Also fixed while in there, each a small silent-wrongness of its own:
- **`upsert_snapshot/1` returned the struct it was handed, not the stored row** (no `returning: true`), so
  every upsert looked like an insert — a caller could not tell a new price from an updated one.
- **`book_id` is now derived at the single write site** and a caller-supplied one is ignored, so the two
  columns cannot disagree. Proved by *"ignores a caller-supplied book_id rather than letting it contradict
  the edition"*.
- **`{:error, :unknown_edition}` is distinct from a changeset error** — an id that resolves to nothing is a
  broken producer, not a validation slip, and collapsing them hid it.
- **The generated migration emitted a bare `:binary_id` with no FK.** A hand-written companion migration
  adds the FK (rung 4 — no orphan snapshots), swaps the unique index, and **guards on the table being
  empty** rather than assuming it, because an edition cannot be inferred from a work that has several.
- **Three tests were fictional and one canonised the bug.** `trigger_price_scrape_job_test` passed an ISBN
  matching no `book_editions` row, so the job had nothing to price and returned `:ok` for the wrong reason;
  the old `prices_test` asserted an ISBN was *not* stale using a snapshot on a different edition, which
  only held under the buggy join.
- **`BookCreatedHandler` now enqueues `%{isbn: …}` alone.** Had it kept sending `book_id`, the job's new
  clause would not have matched and every per-book scrape trigger would have silently become a no-op —
  i.e. the fix would have created a seventh "built but not wired" instance.

**Verification:** `mix test` **2,965 tests / 0 failures**; `dbt test` **240/240**;
`mix proto.sync --check` clean; `just lint-dbt` all gates pass; migration ordering proved on a
**from-scratch database** (create table → add column → FK + index swap). One mutation probe, reverted.

#### ⛔ Two platform defects found while doing P1 — both independent of prices, both worth their own issue

**PF-1 — ✅ FIXED — `mix test` deleted untracked generated migrations, i.e. the test suite mutated the
working tree.**
`Mix.Tasks.Proto.SyncTest` runs a **real** `ProtoSync.run([])` against the actual repo root
(`proto_sync_test.exs:740-744`), then in cleanup deletes migrations that are dated today, match
`_add_*_to_*`, **and are untracked** (`:795-811`). A freshly generated `proto.sync` ADD COLUMN migration
matches all three, so the sequence *"run `mix proto.sync`, then run `mix test` before committing"*
**silently destroys the migration** — and a later test in the same file then fails
`run(["--check"])` with "Proto fields missing from migrations", pointing at the developer's proto change
rather than at the deletion. It cost real time here: the file vanished twice before the mechanism was
found, and the DB still recorded both versions as applied, which makes the state look inexplicable.
The cleanup's own comment shows this has bitten before in a broader form ("Previously this matched
everything-not-`_create_`, which silently deleted unstaged move/alter migrations"). Narrowing the glob
treated the symptom; **the defect is that a test writes to the real repository at all.**

**Resolution (owner: "we can remove it").** The test turned out to assert **nothing about migrations**
despite its name — every assertion was `File.exists?` on Ecto and dbt files — and its `tmp_dir` setup was
vestigial, someone having begun a fixture tree and abandoned it mid-comment (`# Instead, we'll test by
calling run from the real repo root`). `run_generate/3` was **already parameterised by root**, so the
replacement reads from the real repo (buf needs the actual `.proto` files) and writes into `tmp_dir`.

Two things worth keeping from the exercise:
- **My first claim that "deleting it costs no coverage" was wrong.** Bare removal dropped
  `proto_sync.ex` from **80.0% → 39.3%** and total from 82.3% → 81.4%; the generate branch is the only
  thing that exercises the *write* path, which `--check` never touches. The replacement restores it
  (**79.3%**, total 82.1%). Verified: **2,966 tests / 0 failures**.
- **The assertion had to be on reported paths, not on the tree afterwards.** A before/after comparison of
  the working tree is **vacuous**: with no drift, a run against the real root rewrites generated files
  byte-identically and adds no migration, so `git status` is unchanged and the test passes *while the root
  argument is being ignored*. Confirmed by mutation probe — replacing the root parameter with
  `find_repo_root()` is caught only by the path assertion, which then names all ~60 escaped paths. (Also:
  `tmp_dir` lives *inside* the repo root at `apps/core/tmp/`, so "path contains repo root" proves nothing
  either.) Added `apps/core/tmp/` to `.gitignore` — ExUnit scratch space was untracked noise.

**PF-2 — ✅ FIXED (2026-07-28).** The fix was to **delete a suppression, not add one**. `mix dialyzer`
already reported `Total errors: 0` in `:dev`; the only thing failing the gate was the leftover
`~r/Function ExUnit\./` filter, which matches nothing there because `elixirc_paths(:dev)` is `["lib"]`.
`.dialyzer_ignore.exs` is now **empty**, so dialyzer runs with zero ignores and every warning is real.
Worth recording: the filter **did not work in `:test` either** — under `MIX_ENV=test` dialyzer reported
`Total errors: 7, Skipped: 0`, i.e. the regex never matched the very warnings it was documented as
absorbing (`Function ExUnit.Callbacks.__merge__/4 does not exist.` and kin). Since analysing
`test/support/` buys nothing but unresolvable ExUnit internals, `:dev` is the right environment and the
file should stay empty. `just verify` now passes end to end.

**PF-3 — ✅ FIXED (2026-07-28) — latent crash: a delta migration's filename was built from every missing
column, uncapped.**
Surfaced by the replacement test before it seeded real migrations: against an empty migrations directory
every column reads as missing, so `generate_delta_migration/3` builds
`..._add_email_display_name_role_…_handle_to_users.exs` from all ~35 `users` columns and dies with
**`File.Error … file name too long`**. The real repo never hits it because only one or two columns drift at
a time — but adding many fields to a wide table in one go would have made `mix proto.sync` crash.

Two ceilings were reachable, not one: a filename is capped at 255 bytes by the filesystem, and the module
name becomes an **atom**, which the BEAM also caps at 255. And the enabling flaw was duplication — the slug
was derived independently in `proto_sync.ex` (for the filename) and `migration_generator.ex` (for the
module name), so capping either alone would have silently desynchronised them. Now one
`MigrationGenerator.add_columns_slug/2` owns the name, caps it at 120 bytes, keeps as many whole column
names as fit plus an `_and_N_more` summary, and always keeps at least one so it never degenerates to
`add__and_35_more_to_users`. The migration writer also now `mkdir_p`s its output directory, which the Ecto
and dbt writers already did. **Mutation probe:** removing the cap fails both the 255-byte filename
assertion and the `_and_N_more` assertion.

**PF-2 — `just verify` currently fails for everyone, on a dialyzer bookkeeping check, with zero real
errors.** `mix dialyzer` reports `Total errors: 0` and then halts exit 1 on
`Unnecessary Skips: 1 / ~r/Function ExUnit\./`. Cause: that filter is only *necessary* under
`MIX_ENV=test`, where `elixirc_paths(:test)` compiles `test/support` and dialyzer cannot resolve ExUnit
internals — but `scripts/lint-elixir.sh` runs `mix dialyzer` with **no MIX_ENV**, and `mix.exs`'s
`preferred_envs` does not list `dialyzer`, so it runs in `:dev` where the filter matches nothing and
`list_unused_filters: true` halts. **Issue #300 was closed on evidence from the wrong environment** — its
notes cite a `deps-test.plt` baseline, while the gate runs `deps-dev.plt`. This is a
"green audit hides a red gate" instance. Fix is one line either way: add `dialyzer: :test` to
`preferred_envs`, or run the lint step with `MIX_ENV=test`. Until then `verify` never reaches
`test-dbt`/`lint-dbt`, so **dbt changes go unchecked by the headline gate** — those had to be run
individually here. Note also the recipe order matters: `verify` runs `test-dbt` *before* `lint-dbt`
because the latter's `model-has-all-columns` check reads a catalog built from views the former
recreates; running them the other way round gives a false failure.

### Wave 0e — 🟧 Production domain cutover (new, 2026-07-28)

**Why this is in the plan at all:** a hosted domain (`readinginthestacks.com`) was chosen and its certs
linked to the **live production deployment** between the campaign's synthesis and now. The app is
serving on it. Nothing here blocks Phase 1 correctness, but four of the six items are wrong *right now
in production*, which is a different category from the rest of this plan.

**Every claim below was verified against the tree on 2026-07-28**, and two of the reported items turned
out to be different from how they were described. Both corrections are in the table.

| # | Item | Verified state | Severity |
|---|---|---|---|
| E1 | `PHX_HOST` still `thestacks.fly.dev` | ✅ real, and in **four** places — not three. ⚠️ The fourth is the one that wins | 🟧 |
| E2 | The website blocks no AI-training crawlers, though the repo declares it wants none | 🟧 **new finding** — see below (⚠️ **downgraded from ⛔** on a closer read; the original framing was wrong) | 🟧 |
| E3 | `MetricsPusher: push failed: nxdomain` | ✅ real, **⛔ root cause found and fixed, and it is not DNS.** Observability has been dead since the ADR-021 cutover, and prod Grafana with it | ⛔ |
| E4 | `noindex, nofollow` must be removed at launch | ✅ correct pre-launch, and it is a **launch gate**: `apps/core/priv/static/index.html:6` | 🟨 |
| E5 | `min_machines_running = 0` causes cold-start 502s | ✅ real, but ⚠️ **a latency choice, not a correctness one** — see below. **DEFERRED by owner decision (2026-07-28): stays `0`** | 🟨 |
| E6 | `/.env`, `/.aws/credentials` probes return `index.html` | ✅ confirmed harmless — the SPA catch-all (`apps/core/lib/core_web/router.ex:407`). Nothing leaked | 🟨 |

**E1 — four places, and the fourth is the only one that matters.** ⚠️ **Fixing the two files named in
the report would have been silently reverted by the next deploy.** Fly *secrets* override `fly.toml`
`[env]`, and `scripts/deploy-stack.sh:810` sets `PHX_HOST` as a secret — computed as
`"${CORE_APP}.fly.dev"` **unconditionally, for prod and preview alike**. In prod mode `CORE_APP` is
`thestacks-core`, so the deploy script was setting `thestacks-core.fly.dev`, which does not even match
the `thestacks.fly.dev` in `fly.core.toml`. The config file was never the authority.

| Site | Role | Fixed to |
|---|---|---|
| `scripts/deploy-stack.sh:810` | ⚠️ **authoritative** — sets the Fly secret, overrides everything below | `${PHX_HOST_VALUE:-${CORE_APP}.fly.dev}` |
| `deploy/fly.core.toml:13` | `[env]`, used by a bare `fly deploy` | `readinginthestacks.com` |
| `config/runtime.exs:288` | runtime default when `PHX_HOST` is unset | `readinginthestacks.com` |
| `apps/core/config/prod.exs:4` | build-time fallback, overwritten by `runtime.exs` | `readinginthestacks.com` |

The new `PHX_HOST_VALUE` is assigned **only in the prod branch** (`PROD_PHX_HOST` overridable), so
previews keep `${CORE_APP}.fly.dev` and preview E2E is unaffected — the case that would have broken if
the domain had simply been hardcoded. Verified for all three branches (prod, prod-with-override,
preview) before landing.

**The RSS half of the report is wrong.** Confirmation and password-reset links are the real exposure —
generated absolute, so they carried the old host. **Feeds are not affected**: `feeds.ex` uses
`urn:stacks:` IDs and emits no absolute self-link at all. That is not a reprieve, it is a worse finding,
filed under G4 above: a feed with no `rel="self"` and no per-entry link is one a reader cannot click
through from. Fixing `PHX_HOST` would not have fixed it, and would have looked like it had.

**E2 — the website implements none of the AI-crawler policy the repository declares.**

⚠️ **Correction to my first read.** I initially filed this as ⛔ "two `robots.txt` copies diverged, the
real one is never served". That was wrong, and the evidence is in the files' own headers: the root
`robots.txt` cites `https://github.com/erinversfeldcodes/thestacks` and says "See also: ai.txt and
LICENSE", and `ai.txt` says it covers "the contents of **this repository**". **They are repository-level
declarations, not mis-filed website assets** — the same practice as a `NOTICE` file, aimed at whatever
crawls the source. So there is no wiring bug, and `ai.txt` not being served is by design, not a defect.

What survives is smaller but still real:

| Surface | AI-training-crawler policy |
|---|---|
| The **repository** (`robots.txt` + `ai.txt` at root, + LICENSE) | Explicit `Disallow: /` for 13 named crawlers — GPTBot, ClaudeBot, CCBot, Bytespider, PerplexityBot, Google-Extended, … |
| The **website** (`apps/core/priv/static/robots.txt`, the file `Plug.Static` actually serves per `endpoint.ex:21`) | **None.** Only `/api/ /u/ /shelf/ /post/ /listing/` disallowed for `*` |

The intent is documented unambiguously for the source and absent for the site. Given that the site will
host **user-authored** content — shelf descriptions, reading notes, public profiles — the site is the
surface where an opt-out matters *more*, not less. So this reads as an omission rather than a decision,
and it is worth confirming as one.

⚠️ **Masked today by E4, and that is the sequencing constraint.** `noindex, nofollow` suppresses
indexing regardless, so nothing is being crawled now. **Removing `noindex` at launch without adding the
crawler groups first would open the site to precisely the crawlers the repo files name.** E2 before E4.

**Fix:** add the named AI-crawler `Disallow: /` groups to `apps/core/priv/static/robots.txt`, keeping the
existing `*` disallows. Keep both root files as-is — they are a different document about a different
subject. A test asserting the **served** `/robots.txt` body contains a known AI-crawler group is what
keeps this from silently regressing; `CrawlerTelemetry` counts fetches but cannot tell what was returned.

**E3 — ⛔ the error message named the wrong subsystem, and the fix already existed for previews only.**

`nxdomain` reads as a DNS misconfiguration, which is what the report concluded and what I initially
recorded. It is not. Diagnosed on the live prod node (all read-only):

| Probe | Result |
|---|---|
| `Application.get_env(:core, :metrics_push_url)` | `"http://thestacks-victoriametrics.internal:8428"` — **correct** |
| `getent hosts thestacks-victoriametrics.internal` (OS resolver) | resolves to `fdaa:50:3a5a:a7b:11f:688a:6fc0:2` |
| `:inet.getaddr(host, :inet6)` | `{:ok, {…:6fc0:2}}` — **IPv6 resolution works** |
| `:inet.getaddr(host, :inet)` | `{:error, :nxdomain}` — IPv4 fails, as any AAAA-only name must |
| `:gen_tcp.connect(host, 8428, [:inet6])` | **`{:error, :econnrefused}`** ← the actual fault |
| `fly ips list --app thestacks-victoriametrics` | **empty — no IPs allocated at all** |
| VM machine | `started`, `auto_stop_machines = false`, `min_machines_running = 1` |

**The mechanism.** `Mint.Core.Transport.TCP.connect/3` tries IPv6 first when `inet6: true`, then falls
back to IPv4 because `inet4` defaults to true (`deps/mint/lib/mint/core/transport/tcp.ex:30-33`). The
IPv6 attempt is refused — :8428 is exposed only via fly-proxy, never on the instance's direct 6PN
address — and the IPv4 fallback then fails to resolve. **Finch surfaces the fallback's error, so a
connectivity fault is reported as a DNS fault**, which is why this survived a cutover and a
`nxdomain`-shaped investigation. The inet6 Finch pool (`application.ex:107-115`) was correctly
configured and correctly deployed since `8b125381` (Jul 17); it was never the problem.

**The fix already existed in the codebase — for previews only.** `deploy-stack.sh` addressed the preview
VM via `.flycast` (routing through fly-proxy) with a private Flycast IP allocated, and its own comment
documented that direct `.internal:8428` is connection-refused. **The prod branch of that same
conditional used `.internal` and skipped the IP allocation.** Prod had no IPs at all, so neither address
could have worked. Fixed by making both branches take the Flycast path.

⚠️ **Prod Grafana is very likely broken by the same cause and must be verified after the deploy.** Its
datasource hardcoded `http://thestacks-victoriametrics.internal:8428`, justified by a comment claiming
Go's resolver handles the IPv6-only name where Erlang's does not. That comment misread the failure:
resolution was never the obstacle, reachability was, and no resolver fixes a refused port. Both clients
now use the Flycast host. Since nothing has been ingested, expect the prod dashboards to have been empty
rather than merely stale.

⚠️ **Not applied to the running prod app.** The deploy script now allocates the IP and sets the correct
URL itself, so the next prod deploy carries the whole fix. Applying it sooner means
`fly ips allocate-v6 --private --app thestacks-victoriametrics` plus a `fly secrets set` of the
`.flycast` URL — which restarts prod core and invalidates sessions (`boot_id`), so it is a deliberate
call, not a side effect.

**This is a ladder win, and the reason to record it:** the defect class is *"a fix applied to one branch
of a conditional"* — the same shape as ROOT G, and invisible to every test because both branches are
deploy-time shell. The instrument that would have caught it is the **zero-row sweep applied to metrics**:
VM held zero samples, and nothing asserted otherwise. A post-deploy check that prod VM has ingested ≥1
sample in the last five minutes is the guarantee; the error log was actively misleading and cannot be it.

**E5 — the correctness argument for `min_machines_running = 1` was removed by this campaign's own work.**
ROOT H originally read as "scheduled work cannot fire". It was challenged and narrowed correctly: prices
were already event-driven by the P6 change, and all three remaining non-staleness cases (index build,
listing expiry, discovery) were made event-driven during Wave 0d. `ImageRetentionJob` is a safety net,
not a guarantee. **So `0` is now *safe*, and `1` buys latency only** — a real user-facing win (no
cold-start 502 on the first hit, which is also the `auth.setup` E2E flake) at the cost of one always-on
machine.

✅ **Decided (owner, 2026-07-28): stays `0`; latency is a later piece of work.** The value of having
asked is that the correctness question is now settled and recorded, so the next person to see a
cold-start 502 does not re-open it as "the crons must be broken". The reasoning is written into
`deploy/fly.core.toml` next to the setting, with an explicit warning not to infer cron reliability
from it. **Cold-start 502s therefore remain expected** — including the `auth.setup` E2E flake, which
stays a warm-and-retry, not a real failure.

**E6 — no leak, but the catch-all is worth narrowing.** `get "/*path"` is unconditional, so every
unknown path returns 200 + `index.html`. Nothing sensitive is exposed and the probes are internet
background noise. The argument for returning 404 on unknown non-API paths is smaller than it looks
(scanners do not care) — but a 200 on `/.env` makes log triage harder, since a real vulnerability and a
bot probe look identical in the access log. 🟨, and genuinely optional.

**Sequencing within Wave 0e:** E2 before E4 (above, non-negotiable). E1 and E3 are independent
one-liners. E5 is a judgement call. E6 is optional. All of Wave 0e is **XS/S** and none of it blocks
another wave — but E1 and E3 are wrong in production today, so they should not wait for a wave boundary.

⚠️ **E4 (remove `noindex`) belongs to Wave 9's launch gates, not here** — it is the one item that must
*not* be done early. It is listed in this wave only so that its dependency on E2 is recorded somewhere
the launch checklist will find it.

## 🟨 ROOT F — Carrying cost: genuinely dead code (distinct from ROOT G)
**Read F and G together:** F is *delete it, nothing wants it*; G is *finish it, something wants it*. My
first synthesis conflated them, which is how the enrichment verticals nearly got deleted while six of
their sibling stories were live. The discriminator is **does a story want this?** — not "does it have a
caller?".
**Leverage: medium — but it is the cheapest wave in the plan and it shrinks everything downstream.**

Every candidate below carries a `notes/` goal-check. The two largest are **whole verticals with no
consumer**, not stray functions:

| # | Candidate | LOC / files | Goal check |
|---|---|---|---|
| 1 | ⛔ **REVERSED by D7 — do not delete. Route it correctly.** ~~`DiscoverBookstoreEventsJob` + its entire cascade.~~ Owner ruling 2026-07-27: *"let's route it correctly."* The job is not merely dead — it is a **second scraping path that bypasses every safeguard** (no robots.txt check, no rate limiter, no fuse, raw-regex HTML extraction) and it is the only implementation of US-2.4.1, a real story. Moves to **Wave 0c**. What *is* still deletable here: the raw-regex extractor (`~r/<h[23][^>]*>…/`) and the substring author match, replaced by `schema.org/Event` → `.ics` → LLM. The three zero-caller functions in `Enrichment.Events` are still genuinely dead and still go. | ~250 / 3 | **Load-bearing after all** — US-2.4.1 is a storied capability; `phase-portfolio-plan.md:27` schedules it, and the research doc shows a viable structured path exists |
| 2 | ⚠️ **AMENDED by D6 — delete the fetcher, keep the story, re-scope the source.** `FetchReviewsJob` + the review stack: no enqueue site, `ReviewFetcherBehaviour` has **one implementation ever** (`MockReviewFetcher`), and `config.exs:161-164` admits "no real review API integration exists yet". The Together AI summarisation call has **no eval harness**. Deleting the mock scaffolding is still right — but US-2.1.1 must be **re-scoped to sanctioned sources before any replacement is written**: GoodReads retired its public API in 2020, is Amazon-owned, defends aggressively, and is the single highest-ToS-risk item in the design (see the research doc's contract-law finding — liability follows *accepted terms*, so we never log in). Open Library exposes ratings via a real API. | **~580 / 7** | Licensed by ceiling — `phase-1-launch-extension.md:57-58`; instantiates the Bucket-A2 gap in `skills-gap-analysis.md:57-63` (LLM output with no eval layer) |
| 3 | **`RecalculateWearJob` doesn't recalculate anything** — it reads `Shelving.spine_data/1` and logs it. The real computation is event-driven in `Shelving.compute_wear_level/1`, inline on every move. `implementation-mapping.md` hedges: "periodic recalculation **or on shelf-move events**" — two mechanisms described as interchangeable, only one of which exists | 62 / 2 | Not load-bearing — already fully served |
| 4 | `ConfirmDeletionJob` — logging-only stub, no enqueue site; `AccountDeletionJob` never calls it; the real email pattern (`EmailDeliveryJob`, 5 live call sites) exists | 70 / 2 | Not load-bearing — no milestone mentions a deletion-confirmation email |
| 5 | **`Page/ThirdSpaces.elm`** — complete page, decoders and all; no route, never imported; `GET /api/third-spaces` is live | 171 | **KEEP THE CAPABILITY, wire the shape** — `phase-1-launch-extension.md:21-24` flags "claimed complete" already meaning backend-built-but-not-end-to-end (#148/#151). **This is a third instance of that exact failure mode**, and Milestone A's verification pass exists to catch it |
| 6 | `Route.Settings` — `toPath` maps it to `/settings/profile`, so **nothing in the app can ever produce it**; reachable only by typing the URL, then runs 11 duplicated init lines and a separate page title for identical content | ~30 / 6 sites | Not load-bearing |
| 7 | `LogoutCompleted` — a no-op Msg discarding its `Result`, when the file **already has a shared idiom for this**: `FocusResult`, reused at 5 call sites | ~4 | Not load-bearing |
| 8 | **3× `{n,unit}→seconds`** (`auth_controller.ex:350-359`, `guardian_token_sweep_job.ex:75-84` byte-identical, `accounts.ex:1231-1245` near-identical). The code flags its own hazard: *"mirroring AuthController's config shape so the two never disagree"* | ~15 | **KEEP the capability** (real #179/#180 security logic) — collapse to one `Duration.to_seconds/1` |
| 9 | `open_token_family/1` is a strict subset of `rotate_token_family/1` — login always mints a fresh `family_id`, so the upsert can never conflict and inserts identically | 5 | Not load-bearing |
| 10 | 3 phantom CSS tokens (`--link-color`, `--link-hover`, `--parchment-ink`) — exhaustively verified as **the only three**; they sit beside a working example of the pattern (`a { color: var(--accent) }`) | 5 sites | Not load-bearing |
| 11 | `Consent.elm:140,174` raw `data-testid` — the last 2 of 30 sites not using `Util.TestId.testId` (and it doesn't even import it) | 2 | Consistency |

**Two new doc-fiction rows found, both Phase 1 MVP** (adding to ROOT D): `implementation-mapping.md:698`
(US-1.3.2 book detail) names **eight** `Components.*` modules — `CoverImage`, `BookMeta`, `EditionList`,
`ReviewSummary`, `PriceInfo`, `AuthorCard`, `WritingLinks`, `ShelfMover` — **none of which exist**; the
real implementation is one monolithic `Page/BookDetail.elm`. And `:562` (US-1.1.7) names
`Page.Upload.Review`, which doesn't exist either. Note the doc *can* track reality — `:1129` correctly
strikes through a removed module — these rows were simply missed.

**Verified NOT deletable** (checked and excluded): `AgeVerification` / `age_gating_enabled?` is a
deliberate ships-dark kill-switch doing real work at its default (ADR-020); `rate_limiting_enabled`,
the three cache flags and `smoke_tests_enabled` all have genuine dev/test overrides; and **no
Kafka/RabbitMQ/K8s/Terraform generality was ever built** — the `skills-gap-analysis.md:113-122`
Bucket-B ceilings are already honoured, so there is nothing to delete there. That last one is worth
stating: the codebase has *not* been speculatively over-built for futures it disavowed.

---

# Ladder wins — defects moved from "a test might catch it" to "it cannot happen"

| Finding | Caught today at | Could be caught at | Class eliminated |
|---|---|---|---|
| W-14 unverified books | Nothing (rung 8, silent) | **Rung 4**: `verification_source` NOT NULL + CHECK | Every future path that creates a book without verification, and it becomes auditable |
| W-12 hidden-by-default | Nothing | **Rung 2**: one function taking both visibilities; a caller that forgets won't compile | Three copies drifting apart |
| W-5 page forgets 401 | Nothing | **Rung 1–2**: one authed-request wrapper whose result type *must* be handled | Every future page silently opting out |
| W-11 wrong entry point | Nothing | **Rung 2**: one `resolve_or_create` verb; delete the ambiguous ones | Callers picking local-only by accident |
| Notice booleans | Runtime priority chain | **Rung 2**: `LoginRedirectNotice` custom type | Contradictory notices |
| ISBN checksum | App-only | **Rung 4**: `CHECK` constraint | Out-of-band inserts (seeds, migrations, psql) |
| Missing FKs (`auth_token_families.user_id`, `guardian_tokens.sub`) | App-code deletes | **Rung 4**: FK + cascade | Orphan token rows |

---

# The plan

### Wave 0 — Two one-line fixes with outsized payoff
**Why first:** both are proven live, neither needs design, and one is a security hole.
| Issue | Root | Size |
|---|---|---|
| **Password reset must revoke all sessions** — call `Accounts.revoke_all_user_sessions/1` in `do_reset_password/2`, mirroring `user_settings_controller.ex:64-68`, + a test | C | XS |
| **Fix CSP so book covers load** — add `https://archive.org https://*.us.archive.org` to `img-src`, or route covers through the existing R2 re-host (`books.ex:820-830`) and serve from `'self'` | E | XS |

### Wave 1 — Deletions (~1,400 LOC, ~20 files)
**Why here:** never refactor or test code you are about to delete — and Wave 3 touches `Stacks.Books`,
which is easier to reason about once the two dead enrichment verticals are gone. Cheapest wave in the plan.
| Issue | Root | Size |
|---|---|---|
⚠️ **REVERSED — the two enrichment verticals are NOT deletion candidates.** My original advice assumed
enrichment was abandoned Phase-2 scaffolding. It isn't: six of its eight stories run on the Phase 1
crontab (see the #117 correction). Reviews (US-2.1.1) and bookstore events (US-2.4.1) are **unbuilt
siblings of live features**, not dead ends. They move to **Wave 6a** as wiring work:

| Issue | Root | Size |
|---|---|---|
| **Wire the reviews vertical** — `FetchReviewsJob` has no enqueue path and `ReviewFetcherBehaviour` has only a mock. Needs a real fetcher, a cron entry, and — per `notes/phase-portfolio-plan.md:17-22` and `skills-gap-analysis.md:57-63` — **an eval gate before its LLM summarisation ships**. Replaces the 3 "Sentiment data coming soon" placeholders | #117 | L |
| **Wire the bookstore-events vertical** — `DiscoverBookstoreEventsJob` needs a cron entry, and there is **no route at all** for bookstore events; `Enrichment.Events`' two unused functions become the read path | #117 | M |

**Still delete** (genuinely dead, no story wants them):
| Delete `RecalculateWearJob` (it only logs; real logic is inline in `Shelving`) and `ConfirmDeletionJob` (stub) + tests; correct the mapping's "or on shelf-move events" hedge | F | S |
| Collapse `Route.Settings` into `SettingsProfile` (6 sites); fold `LogoutCompleted` into the existing `FocusResult` no-op idiom; delete `open_token_family/1` in favour of `rotate_token_family/1`; inline the 3 phantom CSS tokens; fix `Consent.elm`'s 2 raw `data-testid` calls | F | S |
| ~~Wire `Page/ThirdSpaces.elm`~~ — ⛔ **STRUCK 2026-07-28. Do not do this.** Routing the page is what the
G1 ruling forbids until the data exists: `third_spaces` = 0 and neither `op.third_spaces` nor
`op.bookstores` has lat/lng, so the route would put a permanently empty map on the main nav. Sized `S`
here because only the wiring was counted; the story it serves is not S. See **Deferred with a home** | F | — |
| ~~Wire the shelf-organization UI (#190)~~ — **MOVED to Wave 0b** (2026-07-28), where it is scoped as both drag-and-drop and explicit controls, split by action. Left struck here because this entry predates Wave 0b's insertion and duplicating it is how work gets done twice or not at all | F | → 0b |
| **Introduce `Stacks.Config` (#091)** as the home for the consolidated `{n,unit}→seconds` helper and the ~12 knobs with no non-default setter — the issue and the campaign's duplication finding are the same work | F/#091 | S |

⚠️ **These three plus reading-progress make four instances of "backend built, UI never wired."** That is a
pattern, not four coincidences — `notes/:12-20` already names it as the reason Milestone A leads with
verification. Worth a standing check in the DoD template: *does an endpoint exist that no client calls?*

### Wave 2 — Contracts and constraints
**Why here:** migrations ripple outward, and `verification_source` is the precondition for auditing ROOT A. Squawk runs in `just ci`, not `just verify`.
| Issue | Root | Size |
|---|---|---|
| **`book_editions.verification_source`** (`open_library` / `google_books` / `barcode_unverified`) NOT NULL, backfilled; makes "never verified" auditable and survives enrichment. **Required by D1.** | A | M |
| **`placements.book_edition_id`** reference, completing US-1.5.4 (editions became rows; placements never moved off the `formats` TEXT[]). **Precondition for D3's per-edition ownership annotation on the bookshelf.** Keep `formats` during migration, backfill from primary edition, then retire it | A/D3 | M |
| FKs on `auth_token_families.user_id` + an owner for `guardian_tokens.sub`; drop the app-code compensation in `deletion.ex` | B | M |
| `lower(email)` unique index + downcase-on-write; `CHECK` on ISBN checksum and on the reset-token/sent-at pair | B | M |

### Wave 3 — ROOT A: one canonical verb, and the test that proves it
**Why here:** needs Wave 2's column. ⚠️ **Write the failing test first** — a request for a checksum-valid ISBN that is resolvable via a seamed OL/GB mock and **absent** from `book_editions`. It must go red against today's code (that is the W-11 repro) before any fix lands.
| Issue | Root | Size |
|---|---|---|
| Add `Books.resolve_or_create/1` as the single entry point; point `show_by_isbn` (or the Elm manual-entry flow) at it; keep `find_existing/1` private. ⚠️ **It MUST call `find_same_work/2`** — otherwise this fix introduces W-13 (see D3) | A | M |
| **Per D1:** barcode fast path writes `verification_source: barcode_unverified`; add a terminal-failure path for `EnrichBookJob`; give a still-unidentified book a **provisional UI treatment** so it never reads as a normal entry | A | M |
| Collapse `create/1` and `create_confirmed_book/4` into one transaction (fixes the dropped `google_books_id`); centralise resolver-error mapping so `:circuit_open` ≠ `isbn_not_found` | A | M |
| **Per D3:** wire the US-1.1.8 same-work merge prompt into the ISBN path (the matcher exists; only `confirm/2` calls it), and dedup at the **catalogue** level so two users' editions don't create two works | A/D3 | M |
| **Per D3:** annotate book detail's existing edition toggle with per-edition **owned / on wishlist** state (depends on Wave 2's `placements.book_edition_id`) | D3 | M |
| **Test debt from W-17:** STRENGTHEN `book_controller_test.exs:502-546`; REWRITE the `UploadProgramTest.elm:290-308` mock-echo; STRENGTHEN `upload.spec.ts:529`; fix the two fail-open `status in [201, 422]` assertions | A | M |

### Wave 4 — ROOT C: complete recovery
| Issue | Root | Size |
|---|---|---|
| Tests for reset-token single-use + supersession (the probe is the spec: remove the guard, these must go red) | C | S |
| Build resend-confirmation (US-14.4.2): one endpoint + Login-card affordance + rate limit + no-enumeration; replace the "register again" copy | C | M |
| Fix the silent-`:ok` rate-limited reset; test email-confirm expiry | C | S |

### Wave 5 — ROOT B: make the cross-cutting concerns structural
⚠️ **Do not write per-page 401 tests before this wave** — the refactor would delete them. Land the structure, then test it once.
| Issue | Root | Size |
|---|---|---|
| One authed-request wrapper whose result type forces 401 handling; migrate all 6 settings pages + the 9 duplicated guards | B | M |
| **One visibility predicate** taking placement *and* shelf visibility; replace the 3 copies; fixes W-12 | B | S |
| `LoginRedirectNotice` custom type replacing 3+3 booleans and the priority chain; surface the `decodeFlags` decode failure instead of swallowing it | B | M |
| Distinct copy per failure cause (422 / 401 / network); make `document.title` follow rendered content | B | S |
| One `{n,unit}` impl with a catch-all; one password-validation module; one save-button; one session-minting function | B | M |

### Wave 6 — ROOT E: first impressions
**Depends on Wave 5** for W-12 and the title fixes.
| Issue | Root | Size |
|---|---|---|
| Diagnose and fix the ~30s sign-in (W-1): is `LoginTransitionCompleted` animation-driven or awaiting post-login fetches? Add an in-flight state either way | E | M |
| **Per D2:** rebuild onboarding as upload **+** consent; persist Skip through the **same server path** as advance and delete the localStorage port (that split is W-4's root cause); update the progress dots for the new step count and the dialog's accessible name per step; lighten the scrim so the shelf reads through | E/D2 | M |
| Give the authenticated home a reason to exist (shelf preview / continue reading) | E | M |
| Style the settings surface to match the product; introduce the missing breakpoint so one nav control shows at a time | E | M |
| Unify the Looking-for-a-Home page with its four siblings; hide or fill the empty "coming soon" cards | E | S |

### Wave 7 — ROOT D: reconcile docs with code
| Issue | Root | Size |
|---|---|---|
| Map the 7 unmapped stories (5 MVP + `US-14.4.1/2`); correct `implementation-mapping.md:1857`; rewrite issue #191's stale summary | D | S |
| **Per D2:** amend US-14.1.2 to cover upload **and** consent (neither half deleted); add an `upload` step to #149's canonical step list; correct the acceptance criterion that names localStorage | D/D2 | S |
| **Per D3:** write the missing **catalogue-level** dedup story (US-1.1.6/1.1.8 scope fuzzy matching to "the user's collection" only — nothing governs the shared catalogue), and the **Phase 5 marketplace** story: `listings.book_edition_id` + `quantity`, with dedup keyed on (seller, edition) and different sellers always separate | D/D3 | S |
| Correct the vision-cascade documentation to 2 stages, and **re-cost `notes/` Milestone E** against tiers that exist | D | S |

### Wave 8 — Accessibility and token drift
| Issue | Root | Size |
|---|---|---|
| Fix the "Deep search" checkbox accessible name ("on"); the "Shelf — 1 books" pluralisation; extend keyboard support beyond Escape + 2 focus traps | E | M |
| Fix the 2 contradictory `var()` fallbacks; tokenise the third gold and pick one error red; introduce a spacing scale or record that spacing is deliberately untokenised | F | M |

---

# Decisions taken — 2026-07-27 (owner)

## D1 — Keep US-1.1.2's meaning: verified means *trustworthy metadata*, not just *real digits*
The story's rationale (*"relies on ISBN to ensure accurate metadata"*) and its acceptance line
(*"No book is created. No partial entry is saved."*) stand as written. The barcode fast path may stay
for latency, but a book with placeholder metadata **must not be indistinguishable from a verified one**.

**Consequences (folded into the waves):**
- Wave 2's `book_editions.verification_source` becomes **required**, not optional.
- Wave 3 adds a **terminal-failure path** for `EnrichBookJob` and a **provisional treatment** in the UI —
  a book still titled `"ISBN …"` must read as "we're still identifying this", never as a normal entry.
- `CLAUDE.md:31` stays as-is. The fast path is now **documented debt with a data representation**, and
  "how many unverified books do we have?" becomes an answerable query.

## D2 — Onboarding walks through **both** upload and consent
US-14.1.2's two halves were treated as rival specs; they are both wanted. The flow covers the first
upload **and** the profile/privacy steps.

**Consequences:**
- The story is **amended, not halved**: its narrative gains the consent steps, and #149's canonical step
  list gains an `upload` step. Neither half is deleted.
- **One store, not two.** Today Skip persists to a localStorage port (`Main.elm:2276`
  `saveOnboardingCompleted ()`) while visibility is read from `GET /api/onboarding/status` — so the
  server never learns and wins on every navigation. That is W-4's actual root cause. **Server-side
  (`onboarding_steps`) is the store**; the localStorage port goes, and the acceptance criterion naming
  localStorage is corrected.
- Wave 6's Skip fix becomes "persist Skip through the same API path as advance", and the step count
  moves from 3 to 4+ — so the progress dots and the dialog's per-step accessible name change with it.

## D3 — One dedup model, three different keys
**The principle:** whether the input is an ISBN or an image, **no duplicates in the catalogue or on
bookshelves.** Per surface:

| Surface | Rule | Dedup key |
|---|---|---|
| **Catalogue** | Clicking a book opens **one** book detail page, with a toggle between every variation added to the platform | **work** |
| **Bookshelf** | Book detail indicates **which copies** the owner owns or has on their wishlist | **work**, annotated per **edition** |
| **Marketplace** | Same seller + same ISBN → **one** listing, with the number of copies available shown in the detail | **(seller, edition)** + quantity |
| | Same seller + **different** ISBNs → **separate** items, one per ISBN | |
| | **Different sellers** → always separate listings, even for identical ISBNs | |

**What already exists (verified):** the catalogue's edition toggle is **built** —
`BookDetail.elm:920-923` (`testId "edition-selector"`), `EditionSelected` Msg, hero-edition switching at
`:844`. So the catalogue half needs only the ingest-side work dedup to feed it.

**What is structurally missing (verified):**
- **Bookshelf:** `placements.formats` is `{:array, :string}` (`gen/shelving/placement.ex:21`) — a
  placement records format *labels*, not `book_edition_id`. The system therefore **cannot say which
  copy you own**, only "in hardcover". US-1.5.4 ("Format tracking — now creates `book_editions` rows,
  not a TEXT[]") is **half-delivered**: editions became rows, placements never moved to referencing them.
- **Marketplace:** `listings.book_id` references the **work**, and there is **no quantity column**
  (`20260319000005_create_marketplace_and_monitoring_tables.exs:98-115`). So "same seller, different
  ISBNs → separate items" is not representable (the listing doesn't know its edition), and "same seller,
  same ISBN → one listing with N copies" has nowhere to put N.

**Consequences:**
- W-13 is **no longer an open question** — US-1.1.8 step 3 already specifies the fuzzy same-work prompt,
  and `Books.find_same_work/2` (`books.ex:855`) **exists**, wired into `confirm/2` (`:981`) but **not**
  into `create_from_isbn/1`. Wave 3's `resolve_or_create` **must** call it. ⚠️ Without this, the naive
  W-11 fix ("fall through to `POST /api/books`") routes users onto the one path lacking the check and
  **introduces** W-13 for real.
- The **catalogue-level** dedup question I raised is answered: **yes, wanted.** Two users owning
  different editions must not create two catalogue works.
- **New Wave 2 contract:** `placements` gains a `book_edition_id` reference (completing US-1.5.4), which
  is the precondition for per-edition ownership annotation.
- **Marketplace is Phase 5, not Phase 1.** Its two schema changes (`book_edition_id` + `quantity` on
  `listings`) and the three-rule dedup are **specified now, built later** — captured as a Phase 5 story
  so the spec isn't lost. Attempting it in Phase 1 would be scope creep against a phase that has
  payments, shipping and KYC already deferred.

# Existing backlog evaluated against the code — 2026-07-27

13 open issues were checked against the codebase (not against their tick-boxes). **None is satisfied;
none moves to `issues/complete/`.** Two have consequences for the plan, flagged ⚠️.

| # | Verdict | Evidence | Placed |
|---|---|---|---|
| **117** E2E enrichment pipeline | ❌ **split three ways** | Zero enrichment E2E specs exist. **6 of its 8 stories have live pipelines** on the Phase 1 crontab (prices, author RSS, source discovery, geographic sweep, opt-out, scraper config) — those need the E2E work as scoped. **US-2.1.1 reviews** and **US-2.4.1 events** are unbuilt features, not test gaps. **US-2.2.1 prices** is broken mid-chain (**W-18**) | **Wave 6a** + verify pass · ⚠️ see correction below |
| **120** E2E marketplace | ❌ | 9 tests exist but they are browse/nav smoke ("browse page loads", "nav link visible", "back link returns"). Its own story table marks **US-7.1 "List a Book for Sale" ⬜ to verify** — and no test creates a listing | Phase 5 (out of frame) |
| **123** E2E blog | ❌ | **No blog spec exists at all** (`ls e2e/tests \| grep -i blog` → nothing) | Phase 7 (out of frame) |
| **127** E2E community + accessibility | ❌ | `looking-for-home.spec.ts` has 3 tests (theme class, title visible, empty-state wording). **None** covers US-19.1.1 aria, US-19.1.2 keyboard, or US-19.2.1 list-view toggle. The campaign found live a11y defects: checkbox accessible name **"on"**, `aria-label="Shelf — 1 books"`, keyboard support limited to one Escape listener + 2 focus traps | **Wave 8** |
| **190** Shelf organization | ❌ **fourth "backend built, UI missing"** | Backend complete — `shelf_controller_test` (18) + `shelving_shelf_test` (17) cover index/create/delete/reorder. But **`Api.elm` calls no `/shelves` endpoint at all**, and there is no create/delete/reorder UI. `ShelfMover.elm:9` lists `allBookshelves` — it moves books between **bookshelves** (the 5 collections), not physical **shelves** | **Wave 1** (beside ThirdSpaces) |
| **191** Account recovery | ❌ | Resend confirmation absent entirely; reset does not revoke sessions (proven live, W-7); single-use untested. Its summary is also **stale** — the "no frontend / broken link" claims are false | **Waves 0 + 4** (already) |
| **100** Document audit-only events | ❌ | No such document exists | **Wave 7** |
| **091** `Stacks.Config` module | ❌ | No `Stacks.Config` module exists. Related: the campaign found **3 duplicated `{n,unit}→seconds` impls** and ~12 knobs with no non-default setter — this issue is the natural home for that consolidation | **Wave 1** (merge with the `Duration` helper) |
| **066** Backup & restore verification | ❌ | No backup runbook, no backup/restore script. `notes/phase-1-launch-extension.md:84` independently says *"(Open, not done.)"* and gates it on real user data landing | **New Wave 9** (beta gate) |
| **035** Phase 1 doc review | ❌ **— this campaign is the disproof** | Its DoD says *"implementation-mapping.md reviewed and current — all stories mapped"*. The campaign found 7+ unmapped stories, 8 phantom `Components.*` at `:698`, `Page.Upload.Review` at `:562`, 3 stale settings pages at `:1857`, and a vision cascade documented at 4 stages that is built at 2 | **Wave 7** (ROOT D *is* this issue) |
| **031** Deployment risk assessment | ❌ | No risk or threat document exists. The campaign surfaced exactly the class it would catalogue: **W-7** (reset doesn't revoke sessions), **W-14** (hard-gate bypass, no audit trail), **W-15** (CSP gap) | **New Wave 9** |
| **034** Risk remediation | ❌ **blocked on #031** | Its first DoD item is *"All must-fix-before-launch findings from #031 addressed"* — #031 has produced no findings document | **New Wave 9**, after #031 |
| **025** Vision model eval framework | ❌ **partial credit** | `apps/core/lib/mix/tasks/eval.resolver.ex` **exists** and is genuinely good — an offline, zero-network replay of recorded cases through the real `CandidateScorer.pick_best/3`. But it is a **title-search scorer** eval, not the **vision-model** benchmark #025 specifies: `benchmark/` dir, ≥50 annotated images, `run.py`/`metrics.py`/`compare.py`, report generator, versioned prompts, experiment configs | **New Wave 9** (Phase-2 gate) |

## ⚠️ CORRECTION — my first read of #117 was wrong. Enrichment is mostly LIVE, and it is de facto Phase 1
I initially recommended closing #117 as superseded, generalising from two dead workers to "the pipeline
is dead code." **That was wrong.** The crontab (`config.exs:48-77`) settles it — most of the enrichment
pipeline is wired and runs daily in production config, and the Rust scraper is deployed
(`PASS deploy: scraper deployed` on this preview).

**Per-story state, which is what #117 should actually be split on:**

| Story | Pipeline | Surface | Verdict |
|---|---|---|---|
| **US-2.2.1** prices | ✅ `TriggerPriceScrapeJob` — cron `0 4 * * *` **+** event-chained from `book_created_handler:23`; scraper deployed | ❌ **`BookDetail.elm:1165`: *"Currently passes NotAsked since the API does not yet provide per-book prices."*** `PriceInfo.elm` (149 lines) exists and is fed nothing | ⛔ **broken mid-chain** — see W-18 |
| **US-2.3.1** author activity | ✅ `FetchAuthorRSSJob` cron `0 7 * * *`; `RSSLivenessJob` weekly | needs a drive | **verify** |
| **US-2.5.1** source discovery | ✅ `DiscoverAuthorSourcesJob` cron `0 8 * * *` + `SourceDiscoveryJob`/`ScoreSourceJob` chained; `/admin/sources` live | needs a drive | **verify** |
| **US-2.5.2** geographic sweep | ✅ `GeographicDiscoveryJob` event-chained from `location_updated_handler:69` | needs a drive | **verify** |
| **US-2.5.3** business opt-out | ✅ `POST /api/opt-out` live (`router.ex:107`) | — | **verify** |
| **US-2.2.2** configure scrapers | ✅ scraper + TOML configs; `/admin/scrapers` route live | needs a drive | **verify** |
| **US-2.1.1** reviews | ❌ `FetchReviewsJob` **dead** | 3 × "Sentiment data coming soon" placeholders (seen live) | **unbuilt feature, not a test gap** |
| **US-2.4.1** bookstore events | ❌ `DiscoverBookstoreEventsJob` **dead**; no route | none | **unbuilt feature, not a test gap** |

**So #117 stays open, split three ways:** verify the 6 live stories (that is the E2E work it was scoped
for); treat US-2.1.1 and US-2.4.1 as **feature gaps**; and fix US-2.2.1's missing API as a wiring bug.

**This also reverses Wave 1's deletion advice for two verticals** — see the Wave 1 note. If reviews and
bookstore events are wanted in Phase 1, they should be **wired, not deleted**.

**And it is another ROOT D drift instance:** `implementation-mapping.md:46` labels all of enrichment
**Phase 2**, while six of its eight stories have pipelines running on the Phase 1 production crontab.
The phase boundary in the document does not match the phase boundary in the code.

## ⛔⛔ FINDING W-18 (revised) — US-2.2.1 has never produced a single price, and the chain is broken at BOTH ends
**Severity: ⛔ · Story: US-2.2.1 · Queried directly against the staging-derived preview DB.**

I first found the *last* gap (no API). Asked "but can the scrapers get anything?", I queried the
database. The answer is **no — and nothing has ever tried.**

| Hop | State | Evidence |
|---|---|---|
| 1. Bookstores to scrape | ⛔ **`op.bookstores` = 0 rows** | So the nightly job iterates an empty set — it is a **no-op even when it fires** |
| 2. Scraper service | ✅ built, deployed, 2 TOML targets (`za/exclusive_books.toml`, `za/takealot.toml`) | `PASS deploy: scraper deployed` |
| 3. Job scheduling | ✅ cron `0 4 * * *` + event-chained on `book.created` | `config.exs:51`, `book_created_handler.ex:23` |
| 4. Has it ever run? | ⛔ **`oban_jobs` is completely empty** — no Oban job of any kind has ever executed in staging | direct query |
| 5. Price data | ⛔ **`op.price_snapshots` = 0 rows**, ever | direct query |
| 6. Read API | ⛔ none exists | `BookDetail.elm:1165` |
| 7. UI | ✅ `PriceInfo.elm`, 149 finished lines, fed `NotAsked` | `BookDetail.elm:1165` |

**The verdict is worse and cheaper than "the API is missing".** Two things are built and deployed (the
Rust scraper, the UI component) and connected by a chain with **no data at either end**: no bookstore
rows to scrape from, no endpoint to read through. The TOML configs name Exclusive Books and Takealot,
but nothing links those configs to `op.bookstores`, so the table the job iterates is empty.

**Can the scrapers actually get anything?** *Unknown — and unknowable from the code.* No scrape has ever
executed against a real target. The scraper may work perfectly or not at all; there is no evidence
either way. That is the honest state of US-2.2.1.

**This makes #117's first task concrete, and it is not writing a test.** Before any E2E spec: seed
`op.bookstores`, run **one** scrape against one real bookshop, and see whether a `price_snapshot` row
appears. If it does, expose the endpoint and feed `PriceInfo` (small). If it doesn't, the two TOML
scrapers need repair against live HTML — which is unbounded work and a different issue entirely.

**Related, same query:** `bookstore_events` = 0 (consistent with its worker being dead), and
**`partners` = 0** — no partner has ever been onboarded, which also means `GET /api/books/:id/availability`
(partner stock, on the book-detail page) has never had data to return either.

**Pattern note:** this is the fifth "built but not wired" instance and the only one that is *actively
burning resources* — nightly cron plus per-book event triggers against an empty set. It is also the
clearest argument for the standing DoD check below: **a pipeline whose output table has zero rows in
staging has never been proven, whatever its tests say.**

**And it fails silently as success.** `TriggerPriceScrapeJob.perform/1` calls `Prices.all_stores()`
(which reads `op.bookstores`), and on an empty list logs
`"nothing to scrape (stale=… stores=0)"` and returns **`:ok`**
(`trigger_price_scrape_job.ex:27-41`). So the job is *green* every night while doing nothing — no error,
no alert, no failed-job row. A chain break that reports success is the hardest kind to see.

### ✅ RESOLVED 2026-07-27 — the TOML/CSS design is abandoned. See the research doc.

Full evidence: **`plans/scraper-architecture-research-2026-07-27.md`**. Owner approved all five decisions
on 2026-07-27. Summary of what changed and why the "write 11 TOMLs" plan above is dead:

| Measured fact | Consequence |
|---|---|
| **8 of 10** reachable targets expose a public product JSON API with real prices (6 Shopify `/products.json`, 2 WooCommerce Store API) | Two platform adapters, not twelve site configs. No HTML parsing, no CSS selectors, no LLM in the price path |
| **Shopify storefront search never indexes ISBNs** — 0 hits for stocked ISBNs at exclusivebooks, wordsworth, stellenboschbooks, bridgebooks; not in `sku`, not in `handle` even when handle == ISBN | `query_template = "{isbn}"` is unimplementable on 6 of 10 targets. The premise of the existing design is false |
| Exclusive Books search HTML is client-rendered: 372KB, **zero** matches for all four configured selectors | `za/exclusive_books.toml` has never been capable of working |
| **`Disallow: /search`** + **`Crawl-delay: 10`** in exclusivebooks robots.txt; `/products.json` permitted; no other target restricts anything | The existing TOML aims at the single forbidden path in the whole target set, while ignoring the permitted one |
| Open Library: one ISBN → work → **151 editions / 76 distinct ISBN-13s** (Sapiens: 86/73) | Edition discovery needs no shop-catalogue harvesting. ⚠️ and must be **capped** before reaching the price layer — 76 × 8 stores = 608 requests per work |
| Exclusive Books stocks **six ISBNs** for one work (two Spanish) at different prices | A price is a fact about an **edition**. `price_snapshots.book_id` is the wrong grain |

**Owner decisions, all approved:**
- **D4** Adopt the capability-probe architecture in place of the eleven TOMLs. Platform is a *derived,
  timestamped observation with a canary assertion* — never hand-authored config. Bookshops replatform, and
  a stored `platform = "shopify"` turns a replatform into a silent outage.
- **D5** Re-key `price_snapshots` to `book_edition_id` now, while the table is empty — via
  `stacks/common/v1/enrichment.proto` + `mix proto.sync`, **not** a hand-written migration.
- **D6** Re-scope reviews (US-2.1.1) to sanctioned sources before any fetcher is written. GoodReads
  retired its public API in 2020, is Amazon-owned, defends aggressively, and is the highest-ToS-risk item
  in the design. The fetcher is mock-only today, so nothing is lost.
- **D7** Route `DiscoverBookstoreEventsJob` through the acquisition spine **correctly** (owner: *"let's
  route it correctly"*) — not delete it. It currently scrapes with no robots check, no rate limiter and no
  fuse, from a cron.
- **D8** Prices become lazy with a staleness TTL, not a nightly sweep. This also disposes of the ~20-hour
  batch and the rate-limit danger of the twelve seeded targets.

**⛔ Owner hard rule (2026-07-27): robots.txt stops the scrape.** On a disallow for the path we want,
**stop there** — no fallback to another path or tier. **Retain the configuration** so that if the disallow
is ever lifted, scraping resumes automatically. `robots_blocked` is therefore a *state of the store*
(`{blocked_path, matching_rule, observed_at}`), re-checked on the probe cadence — not a config deletion.
This rule is violated in **three** places today; see Wave 0c.

Per-store capability, measured (n=50 from each store's own API, so all stocked):

| Store | Platform | Per-ISBN lookup | How |
|---|---|---|---|
| exclusivebooks | Shopify | ✅ **direct** | `/products/<isbn>.js` → 200; **404 if unstocked** (handle == sku == ISBN, 50/50) |
| booklounge | WooCommerce | ✅ **native search** | Store API `?search=<isbn>` → exactly 1 correct hit (`sku` 30/30) |
| bridgebooks | Shopify | ⚠️ index needed | `sku` 49/50; handle *contains* but ≠ ISBN → direct 404 |
| stellenboschbooks | Shopify | ⚠️ index needed | `sku` 50/50, handle 0/50 |
| wordsworth | Shopify | ⚠️ index needed | `sku` 46/50, handle 0/50 |
| clarkesbooks | Shopify | ⚠️ index needed | ISBN in free-text body only, 35/50 |
| ikesbooks | Shopify | ❌ **none** | no ISBN anywhere in 50 products → fuzzy title match is the *only* path |
| lovebooks | WooCommerce | ❌ none | no ISBN in `sku` (0/30) |
| loot, fortunatefinds | — | ❌ none | no product JSON API at all |
| kalkbaybooks | WordPress | ⚠️ re-probe | **503** at probe time — and RFC 9309 treats 5xx as *full disallow* |
| skoobs | — | ⚠️ re-probe | connection error on plain `http://` |

**The index retains a pointer, not a catalogue.** Owner constraint: *"we aren't aiming to replicate their
entire catalog on this site."* So: paginate transiently → keep only records whose ISBN ∈ our
`book_editions` → retain `(store_id, isbn, product_path, isbn_source, seen_at)` → **discard every title,
description, image and price from the sweep.** Price comes from a separate per-ISBN fetch of only the
editions we hold. `bulk_index_allowed` defaults **false** per store.

*(`za/takealot.toml` is not on the owner's list and its design is equally dead — delete with the rest.)*

## ⚠️ #025 became more important, not less
`notes/` Milestone E calls the eval harness a *"HARD PREREQUISITE"* for the vision redesign. The campaign
found (**W-16**) that the documented 4-stage cascade is built as 2 — so Milestone E's cost savings are
projected against **two cheap tiers that do not exist**. #025 is therefore the gate on *both* the
redesign and on re-costing the plan honestly.

### Wave 9 — Launch-gate issues from the existing backlog (new)
**Why last in this plan, and why they are still gates:** none blocks Phase 1 *correctness*, but three of
them block the **beta** and the **Phase 2 vision work**, per `notes/` Milestones D and E.
| Issue | Root | Size |
|---|---|---|
| **#031** — run the deployment risk assessment; **seed it with W-7, W-14, W-15** rather than starting cold | — | M |
| **#034** — remediate #031's must-fix findings (blocked on #031) | — | M |
| **#066** — backup & restore verification, before real user data lands (`notes/:84`) | — | M |
| **#025** — the vision-model benchmark (`benchmark/` + annotated corpus). Gates the Milestone E redesign **and** the re-costing that W-16 forces | — | L |
| **E4** — remove `noindex, nofollow` from `apps/core/priv/static/index.html:6`. ⛔ **Blocked on Wave 0e's E2** — doing this while the served `robots.txt` lacks the AI-crawler groups opens the site to every crawler that file was written to exclude | 0e | XS |
| **E2 verification** — re-fetch `/robots.txt` from the live domain and confirm the served bytes carry the crawler groups. The zero-row check's equivalent for a static asset: *what the server returns*, not what the repo contains | 0e | XS |

# G1 / US-3.1.1 — brought in, and where the line was drawn (2026-07-28)

**Owner decision:** *"let's bring it all in"*, with two constraints — build geocoding cheap now
(Nominatim) but easy to swap to Google later, and *"do everything that makes sense to happen in wave 0
as part of wave 0 and subsequent steps in later waves if needed, however it needs to be thoroughly
documented in the plan."*

**The line I drew, and why.** Wave 0b's premise is *"wire what is already built"*. Steps 1–3 make the
**data exist** — they finish a table, a producer and a live endpoint that were already half-built, and
they close a rung-8 correctness risk. Steps 4–6 are **new construction**: a third-party ADR, the
project's first Elm port, and a page that does not exist. That is a different kind of work, so it goes
to a later wave rather than being renamed Wave 0.

| Step | Where it landed | Why there |
|---|---|---|
| **1** lat/lng + `nearest_bookshop_km` on both tables, indexed | ✅ **Wave 0** (`2f4288cb`) | A proto contract change: cheapest early, additive forever. Also made a **live** endpoint's advertised contract honourable |
| **2** Geocoding at approval, provider-swappable | ✅ **Wave 0** | Prerequisite of 3, and the thing that turns an approval into a position |
| **3** `approve_source/1` creates the `third_space` — the only producer | ✅ **Wave 0** | The rung-8 gate: producing rows *before* 1–2 would turn "empty" into "silently wrong" on a live endpoint |
| **4** Tiles ADR (provider, proxy-vs-direct, terms clause) | ✅ **Wave 0** — ADR 022 | Terms were fetched and read on 2026-07-28 rather than deferred. ⚠️ Two of three objections to Google **dissolved**; what rules it out is a verified chain ending in the `unsafe-eval` prohibition. Provider shortlist still open, on purpose |
| **5** The narrow Elm port | ⏭ **later wave** | The project's **first** port; sets a precedent every later argument will cite. Wants its own review, not a footnote in a data-layer wave |
| **6** Route the page + cork board | ⏭ **later wave** | ⛔ Gated on 1–3 having produced rows in a real environment. Routing an empty map onto the main nav promises what it cannot deliver |

**What Wave 0 now delivers on its own, without the map.** `GET /api/third-spaces` is live and already
accepted `lat`/`lng`/`radius_km`; approved space-like sources now become positioned rows, so the endpoint
returns correct geo-filtered results instead of nothing. That is real value independent of steps 4–6 —
which is the test for whether a split is honest rather than convenient.

### ⛔ Zero-row sweep, 2026-07-28 — steps 1–3 are built and have produced nothing

Run immediately after the work landed, because "the tests pass" is not the DoD this plan asks for:

| Table | Rows | Reading |
|---|---|---|
| `op.third_spaces` | **0** | Expected *downstream* of G3: `discovered_sources` = 0, so there has been nothing to approve |
| `op.third_spaces` positioned | **0** | Same cause |
| **`op.bookstores` positioned** | **0** | ⛔ **My own chain break — see below** |
| `op.discovered_sources` | **0** | G3's standing evidence gap |

⛔ **I added the 500 m pairing rule and left it unable to ever fire.** `create_third_space/1` computes
`nearest_bookshop_km` by scanning bookshops *that have coordinates*. **No seeded bookshop has any** — I
added `latitude`/`longitude` to `op.bookstores` and never populated them. So the scan always returns
`[]`, the field is always `nil`, and `list_third_spaces(near_bookshop_km: 0.5)` correctly refuses to
treat `nil` as "near" — which means **the filter that is the page's entire premise can never return a
row**.

Every unit test passes, because each one sets the coordinates it needs. This is exactly the
built-but-not-wired shape ROOT G is about, committed by the person writing the ROOT G section, and it
is worth recording rather than quietly fixing: the instrument that caught it was the **zero-row sweep**,
not the 30 tests written alongside the feature.

### ✅ CLOSED 2026-07-28 — geocoded (owner chose "geocode them"), and the chain is proven live

`Stacks.Workers.GeocodeBookstoresJob` — weekly cron, **strictly serial**, `@throttle_ms 1_100`,
`@batch_size 25`, skips online-only shops (`has_physical: false` — a website is not a place) and never
overwrites an existing coordinate.

⚠️ **The throttle replaced a guarantee, so it is asserted, not commented.** `Nominatim`'s docs said the
**absence** of a batch entry point was what honoured the ~1 req/sec policy. This job *is* that entry
point, so a test asserts `default_throttle_ms() >= 1_000` — lowering it to speed up a backfill now fails
a test with a message explaining whose service it protects. Probe confirmed: dropping it to 200 ms
reddens exactly that test.

**Run for real against Nominatim: 7 of 10 physical shops positioned.** Spot-checked and plausible — Kalk
Bay Books at `-34.125, 18.450`, Love Books in Melville, Stellenbosch Books in Stellenbosch, Clarke's at
`-33.925, 18.416`.

**Then the full chain, proven end to end** (`op.discovered_sources` was also never seeded — G3's
zero-row cause — so five real pending sources were added; approval is a human act and remains the only
producer):

| Step | Observed |
|---|---|
| `op.third_spaces` | **0 → 1** — "Truth Coffee Roasting" |
| Geocoded | `-33.9282267, 18.4227333` |
| `nearest_bookshop_km` | **0.678 km**, computed against the real geocoded shops |
| `third_space.created` | emitted, `geocoded: true` |
| `list_third_spaces(near_bookshop_km: 5.0)` | **1 row** |
| `list_third_spaces(near_bookshop_km: 0.5)` | **0 rows** — correctly excluded at 678 m |

### ✅ The 500 m rule became two tiers (owner ruling, 2026-07-28)

The live data produced a product finding — Truth Coffee at **678 m** from Clarke's, walkable, excluded by
a hard cutoff — which I recorded rather than acting on, because changing a story's stated rule is the
owner's call. The ruling came back: *"500m is a rule of thumb: further away should only be included if
the ratings are high."*

Implemented as a genuine trade-off, not a wider circle:

| Tier | Qualifies |
|---|---|
| **1** — within `near_bookshop_km` | on distance alone |
| **2** — beyond it, within `Enrichment.curated_within_km/0` | **only if `curated`** |

`curated` / `curated_note` on `op.third_spaces` are the mechanism — the same fields US-3.1.1 §4 already
obliged as the source of "well-regarded", now carrying the distance trade-off as well. That is a good sign
about the original decision: one field served two purposes without being stretched.

⚠️ **Two ways this could have been done wrong, both tested and probed:**
- **Tier 2 without the curation requirement** is just a bigger radius, and "the ratings are high" would
  mean nothing. Probe: removing `curated == true` reddens the uncurated case.
- **Tier 2 without an outer bound** would let a curated café 40 km from any bookshop onto a map answering
  "where can I read *near here*". Asserted finite, and the 40 km case is tested.

### ⚠️ Chains need per-branch rows — worse than "one arbitrary branch"

Owner: *"there are a lot of Wordsworth and Exclusive Books branches, these are chains."* Correct, and my
original framing understated the consequence. One row per chain does not merely give an *approximate*
location — it makes the pairing rule **miss real pairings**. Wordsworth's row geocoded to `23.37°E`
(Garden Route), so a third space beside a Cape Town Wordsworth is not paired with it at all.

It fails safe (proximity is understated, never faked), which is why it is 🟧 rather than ⛔. But it is a
**data-model gap**: `op.bookstores` needs one row per branch, or a branches table. Not a geocoding fix,
and not attempted here.

**Related, same root cause:** 3 of 10 physical shops did not geocode (Fortunate Finds, Ike's Books, **The
Book Lounge**) because `op.bookstores` has **no city or address**, so the query is only `"<name>, ZA"`.
Both problems point at the same missing structure — a bookshop record that knows *where a branch is*.

**Two data gaps recorded rather than papered over:**
- **3 of 10 physical shops did not geocode** (Fortunate Finds, Ike's Books, **The Book Lounge** — a
  well-known Cape Town shop). Cause: `op.bookstores` has **no city or address**, so the query is only
  `"<name>, ZA"`. Adding a `city` field would likely fix all three; deliberately not done here to avoid
  more proto churn mid-wave. Those shops simply do not participate in pairing until positioned.
- **Chains resolve to one branch**, as predicted in the job's docs and now observed: Wordsworth Books
  geocoded to `23.37°E` (Garden Route), not Cape Town. Per-branch rows are a data-model change, not a
  geocoding one.

---

**The decision this replaced.** Coordinates for eleven real bookshops had to come from somewhere, and
the two options were not equivalent:
- **Geocode them** — reuses `Stacks.Geocoding`, so the addresses are authoritative rather than guessed.
  ⚠️ But it requires a *batch* entry point, and `Stacks.Geocoding.Nominatim`'s docs currently claim the
  **absence** of one is the structural guarantee that honours the ~1 req/sec policy. Adding it means
  adding a real throttle and testing it — the guarantee cannot be downgraded silently.
- **Seed literal coordinates** — no throttle needed, but it hardcodes approximations for real
  businesses, and a wrong coordinate is worse than none: it places a shop somewhere it is not and the
  500 m rule then pairs the wrong things.

## Step 4 — ADR 022, and a reasoning failure worth recording

**Written, not deferred:** `docs/decisions/022-map-tiles-and-geocoding-provider.md`. The terms were
fetched and read on 2026-07-28 after the owner challenged the justification I had recorded.

⚠️ **My original reason for rejecting Google was circular and I should not have written it.** I wrote
that Google's terms "require Google's own map alongside, which contradicts the tile decision below" —
a claim that contradicted a decision made two paragraphs earlier *in the same document*. The owner
asked the obvious question — *"shouldn't we be able to place Google's map to the left of the cork
board?"* — and the answer was yes. A decision is not a constraint, and dressing one as the other is how
a preference acquires the authority of a rule.

**On reading the sources, two of my three objections dissolved:**

| Objection | Verdict |
|---|---|
| "Terms restrict caching coordinates" | ❌ **Wrong.** 30 days applies to *temporary* caching; lat/lng may be cached **indefinitely** "solely to support direct, end-user facing functionality of the customer application that initiated the request" — exactly our case. `nearest_bookshop_km` is fine to keep |
| "Requires Google's own map alongside" | ❌ **Wrong shape.** The policy is narrower: results *displayed on a map* must be on a Google map; displayed otherwise, attribution suffices |
| "Conflicts with the strict CSP" | ✅ **Correct, and decisive** — see the chain below |

**What actually rules Google out is a three-link chain, every link cited in the ADR:**

> Google **Geocoding** → its policy requires results *displayed on a map* to be shown on a **Google
> map** → Google Maps JS requires **`'unsafe-eval'`** in `script-src`, even in *Google's own
> recommended strict CSP* → `unsafe-eval` is forbidden outright (`CLAUDE.md:144`,
> `security.md:139`); the live policy is `script-src 'self'`.

**The best consequence: the CSP does not change at all.** Proxied tiles keep `img-src 'self'`, so this
decision costs nothing in the policy — the strongest form the outcome could take.

⚠️ **Escape hatch, recorded so nobody re-derives it:** Google Geocoding *is* usable where results are
**not displayed on a map** (attribution suffices) — a list, an admin queue. It is the *map* that
forecloses Google, not the geocoding, and `Stacks.Geocoding` still supports that case.

**Deliberately left open:** *which* non-Google tile provider. That turns on each provider's stance on
proxying — several restrict it or reserve it for paid tiers — and choosing one without reading those
terms would repeat precisely the mistake this ADR corrects. Vector tiles proxy less cleanly than
raster; worth knowing before the shortlist.

**The transferable lesson.** Two of three objections were written from memory and were wrong; the one
that held needed a *chain* of three verified facts to state correctly. The persona's own rule —
never cite a source from memory — applies to terms of service exactly as it does to code exemplars,
and this is the second time in this campaign that fetching beat recalling.

## What steps 1–3 actually fixed, beyond adding columns

Four defects surfaced that were not in the original G1 description:

1. ⛔ **`limit` was applied before filtering** in `list_third_spaces/1`. The query took N rows in
   unspecified order and *then* filtered by radius, so **the nearest space could be invisible while a far
   one showed**. ⚠️ My first test for this was **vacuous** — the bounding box filters in SQL, so
   out-of-city decoys never reached the limit. The probe caught it; the real test places decoys in the
   **box corners** (inside the box, outside the circle) and fails with the fix removed.
2. ⛔ **Opted-out spaces were returned.** A business that asked to be delisted stayed on the map — the
   exact harm US-2.5.3 exists to remedy.
3. 🟧 **The `op.space_type` enum could not express the story's categories.** It was
   `{reading_group, cafe, bookshop, festival, market}` — an *events* taxonomy from the discovery stories —
   against US-3.1.1 §3's eleven *places-to-read* categories. **Only `cafe` overlapped.** The category
   filter was unbuildable as specified, and nothing had compared the two lists because they were written
   by different stories months apart. Extended additively; the original five are still in use.
4. 🟧 **The hand-written changeset silently dropped the new columns.** Changesets in `Stacks.Enrichment`
   are hand-written *on purpose* so validation survives schema regeneration — which means
   `mix proto.sync` adding a column does **not** make it writable, and a field missing from the cast list
   is discarded without error. Every space was created unpositioned until the cast list was updated. Worth
   knowing: **this will happen again** on the next proto field added to a hand-cast schema.

## Deferred steps 5–6 — dependency order preserved

⚠️ **Step 4 is DONE** (ADR 022, 2026-07-28) — it was in this section when written and is not
any more. Only the Elm port and the map page remain deferred.

⚠️ **Why this section exists.** G1 was removed from Wave 0b on 2026-07-28 with a stated reason, and a check
on 2026-07-28 found it had landed in **no future wave** — the identical "moved and then untracked" pattern
that lost C3 and C4 for a fortnight. Worse, the plan contained a *contradiction*: Wave 1 still carried
"Wire `Page/ThirdSpaces.elm` (route + import)" sized `S`, which is precisely the action the deferral
forbids. Both have been struck above. A deferral without a home is not a decision, it is an omission with
better paperwork — so this is the home.

**Scope note — and ⛔ a phase inversion in the mapping.** `docs/implementation-mapping.md:48` files
US-3.1.1 under **Phase 4**. But `:1472` records **US-9.4.2 (User-Submitted Third Spaces), Phase 3**, whose
stated dependency is *"US-3.1.1 (Third Spaces cork board exists)"* — and its frontend is a "Pin a new
space" button **on that cork board**. So a Phase 4 story blocks a Phase 3 story, and the dependency runs
backwards through the phase order. The Phase 4 label is wrong; the need is Phase 3 or earlier. Worth
fixing in Wave 7 (ROOT D) rather than left to be rediscovered.

⛔ **The mapping also documents a producer that has never existed.** `:2115` lists
`DiscoverThirdSpacesJob` as *"Scheduled (weekly)"*. There is **no such module** anywhere in
`apps/core/lib` and no crontab entry. That is why `op.third_spaces` was 0 — not a fixture gap, an absent
producer that the documentation asserts is running. Same defect class as ROOT D, at its most expensive:
the doc says the pipeline exists, so nobody looks.

✅ **Resolved differently than the mapping implies.** The producer now exists as
`Discovery.create_third_space/1`, driven by **approval**, not by a weekly job — because US-3.1.1 §4 makes
human approval the only permissible producer. So the mapping's `DiscoverThirdSpacesJob` row should be
**deleted**, not implemented; a scheduled scraper writing that table is the design the story rejects.
Fold into Wave 7 (ROOT D) with the phase-label fix.

⛔ **`GET /api/third-spaces` is live and its geo contract is unkeepable.** The route exists
(`router.ex:126`) and the controller accepts `lat`, `lng` and `radius_km`
(`third_space_controller.ex:13-16`). The filter behind it, `Enrichment.within_radius?/4`, resolves a
space's position by looking its **`city` string** up in a hardcoded **six-entry** `@city_coords` map
(`enrichment.ex:184-191`) — so any space outside those six cities is silently dropped, and two spaces in
the same city are treated as equidistant. It measures distance from a city centroid while advertising
distance from a point.

**This makes the ordering below a correctness constraint, not a preference.** Right now 0 rows mask the
defect. **Building the producer (step 3) before the columns (step 1) would convert "empty" into "silently
wrong" — rung 8, the worst rung on the ladder** — because a live endpoint would start returning confident,
incorrect answers. Steps 1 and 2 are not preparatory tidying; they are what stops step 3 shipping a bug.

**The story is fully specified.** `docs/user_stories/US-3.1.1-third-spaces-map.md` — all six open decisions
taken (reader-facing category filters; owner-curated "well-regarded" with no stars anywhere; `third_space`
created **only** by source approval; one narrow Elm port; hosted tiles **proxied** so no reader IP reaches a
third party; plain lat/lng + bounding box, not PostGIS).

**Dependency order — the wiring is last, not first.** This ordering is the whole point of the deferral:

| # | Work | Why it must precede the next | Size |
|---|---|---|---|
| 1 | **`latitude`/`longitude` on `op.third_spaces` *and* `op.bookstores`** — `.proto` + `persisted.exs` + `mix proto.sync` | The 500 m rule cannot be computed at all without them. Contracts before consumers | S |
| 2 | **Geocode at approval, and store nearest-bookshop distance** | Precomputed, not per-request — recomputing across a viewport on every pan is the query that would later force PostGIS for the wrong reason | M |
| 3 | **`Discovery.approve_source/1` creates the `third_space`** — the only producer | Until this exists the table stays at 0 rows and every downstream surface is empty | M |
| 4 | **ADR: tile provider + proxy-vs-direct**, incl. the terms clause consulted | Must be merged *before* the map is built; if direct, the privacy policy needs the third party named (a launch-gate item) | S |
| 5 | **The narrow Elm port** — camera/pins out, viewport/click in, debounce in Elm | The project's first port; sets the precedent every later argument will cite | M |
| 6 | **Route the page + cork board** — the item Wave 1 wanted to do first | ⛔ Lands **only** when 1–3 have produced rows. This is the gate | M |

**Two findings banked from the specification pass, worth keeping even if the story slips:**
- `Stacks.Enrichment.haversine_km/4` (`enrichment.ex:244`) is already written and correct; it is useless
  only because `within_radius?/4` joins against a hardcoded **six-entry** `@city_coords` map. Step 1 makes
  existing code work rather than adding new code.
- **Antimeridian panning breaks a naive bounding box** (`east < west` past ±180°), and §1 explicitly puts
  "drag across the globe to Shanghai" in scope. Two boxes, with a test — a plain `between` returns nothing
  there and fails silently.

**`Page/ThirdSpaces.elm` must not be deleted in the meantime.** It appears in ROOT F's dead-code list
(item 5) because it is unreachable, which is true but misleading: the capability is wanted and specified,
so it is *unwired*, not dead. Deleting it would throw away 171 LOC that step 6 needs.

# Deliberately not in this plan
Age-gate Verify affordance (withdrawn, ADR-020 §2 — only the stale *mapping reference* is in Wave 7) ·
splitting `Main.elm` on line count (the repetition is the cost of per-page `OutMsg` typing; Wave 5
removes some as a side effect — re-evaluate after, per Czaplicki's *Life of a File*) · splitting
`Stacks.Books` (same reasoning; Wave 3 extracts the resolution seam, which is the part that actually
wants its own module) · community moderation, POSSE, the JEPA vision redesign (`notes/` places all three
outside this phase; the redesign is gated on an eval harness that does not exist yet).

# What this costs and what it buys

Roughly **32 issues across 10 waves** (Wave 0e added 2026-07-28), front-loaded with two XS fixes and a
deletion pass, with the expensive middle in Waves 3–6. Waves 0c and 0d are **complete**; Wave 0b is
partially complete (G2 and the G4/G6 server halves done, G5 and the two UI halves remaining, G1
deliberately deferred).

At the end: a user can add a book they own by typing its ISBN; no book can enter the catalogue without
a recorded verification source, and you can query for the ones that lack one; a locked-out user can
recover without support and cannot be replayed against; a session expiring mid-form lands them at login
instead of a dead retry; a new user's shelf shows their books rather than a wash of 35%-opacity
"hidden" spines; book covers appear; and the documentation describes the software that exists.

**The single most important line in this plan:** ROOT A is one root with six symptoms, and its fix is a
column plus one function plus one test that goes red today. That is the highest ratio of
guarantee-gained to effort-spent anywhere in Phase 1.
