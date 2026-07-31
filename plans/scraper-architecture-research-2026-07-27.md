# Scraper Architecture — Research
**Date:** 2026-07-27 · **Status:** ✅ complete — empirical probing, literature review and requirements
survey all landed; recommendation ready for a decision
**Question:** before writing eleven TOMLs, what scraper architecture should The Stacks actually build?

## TL;DR — the current design is wrong in a way that makes it *simpler*, not harder

Per-site CSS selectors are the wrong abstraction, and so is the per-site *platform name*.

1. **8 of 10 reachable targets expose a public, unauthenticated product JSON API with real prices.** Two
   platform adapters, not twelve site configs. No HTML parsing and no LLM for the price path at all.
2. **Shopify storefront search never indexes ISBNs** — proven across four stores against ISBNs they
   demonstrably stock. `query_template = "{isbn}"` cannot work on 6 of our 10 targets, ever.
3. **Platform must be detected, never configured.** Bookshops replatform; a stored `platform = "shopify"`
   turns a replatform into a silent outage indistinguishable from "not stocked". Capability becomes a
   timestamped observation with a canary assertion.
4. **Edition discovery comes from Open Library, not from shop catalogues** (verified: one ISBN → 151
   editions / 76 ISBN-13s), so the owner's "notice new variations" requirement needs no bulk harvesting.
5. **The single most valuable fix is a type, not a scraper:** today "this shop doesn't stock this edition"
   and "our extractor is broken" are the same `PriceNotFound`. Separating them is a Bug-Catching-Ladder
   climb from silent wrong behaviour to observable state.
6. **The LLM's place is configuration-time wrapper induction and events** — not the price path, where the
   data is already structured.

---

## Empirical findings — measured, not assumed (2026-07-27)

### 1. Platform fingerprint of the 12 owner-specified targets

| Site | Platform | Product JSON API | Sample price |
|---|---|---|---|
| wordsworth.co.za | Shopify | ✅ `/products.json` | R215.00 |
| exclusivebooks.co.za | Shopify | ✅ `/products.json` | (works; first item R0.00) |
| clarkesbooks.co.za | Shopify | ✅ `/products.json` | R320.00 |
| bridgebooks.co.za | Shopify | ✅ `/products.json` | R200.00 |
| ikesbooks.com | Shopify | ✅ `/products.json` | R180.00 |
| stellenboschbooks.co.za | Shopify | ✅ `/products.json` | R480.00 |
| booklounge.co.za | WooCommerce | ✅ `/wp-json/wc/store/v1/products` | 24500 (cents) |
| lovebooks.co.za | WooCommerce | ✅ `/wp-json/wc/store/v1/products` | 35000 (cents) |
| fortunatefinds.co.za | WooCommerce | ❌ Store API 404 (disabled) | — |
| loot.co.za | unidentified | ❌ not JSON | — |
| kalkbaybooks.co.za | WordPress | ⚠️ **503** at probe time | — |
| skoobs.co.za | — | ⚠️ **connection error** (plain `http://`) | — |

**6 Shopify + 2 WooCommerce = 8 covered by two adapters.** Two platform adapters, not twelve
site configs.

### 2. The existing TOML approach cannot work — two independent reasons
Verified against `exclusivebooks.co.za` with `za/exclusive_books.toml` as written:
- **Search results are client-rendered.** `GET /search?q=<isbn>` returns 200 / 372KB of HTML that
  contains **neither the book nor any price string**. Every configured selector
  (`.product-price`, `.price`, `.product-name`, `.availability`) matches **zero** elements.
- **Shopify storefront search does not index ISBNs — on any store, in any field.** This is now proven
  rather than inferred, across four stores:

| Store | ISBN queried | Is it stocked? | `/search/suggest.json?q=<isbn>` |
|---|---|---|---|
| exclusivebooks | `9780749397050` | ✅ yes — R400.00, `sku` == ISBN, `handle` == ISBN | **0 hits** |
| exclusivebooks | `9788497592581` | ✅ yes — R411.00 (Spanish ed.) | **0 hits** |
| wordsworth | `9780723263661` | ✅ yes — in `sku` | **0 hits** |
| stellenboschbooks | `9780349415864` | ✅ yes — in `sku` | **0 hits** |
| bridgebooks | `9781049281483` | ✅ yes — in `sku` | **0 hits** |

Every one of those ISBNs is demonstrably stocked, and Shopify search returns nothing for all of them.
Search indexes title/body/tags/vendor — **not `sku`, and not `handle` even when the handle is literally
the ISBN.** So `query_template = "{isbn}"` can never match on a Shopify store, whatever the selectors
say. That is **6 of our 10 reachable targets**, killed by a property of the platform rather than a
misconfiguration.

**⚠️ Correction to an earlier draft of this document.** I first wrote that search "does not index ISBNs"
on the evidence that `9780156001311` and `9780099590088` returned empty. The owner correctly pointed out
that Exclusive Books stocks six *different* editions of The Name of the Rose (two Spanish), none of them
`9780156001311`. Both facts turned out to be true and I had tangled them:
`GET /products/9780156001311.js` → **HTTP 404** (genuinely not stocked), while stocked ISBNs return
**0 search hits** but **HTTP 200** on the direct product endpoint. Two distinct failure modes that the
current design collapses into one indistinguishable "no price found".

**That collapse is itself the most important finding in this section.** The current design cannot tell
*"this shop does not stock this edition"* (a permanent, correct, useful answer worth storing) from
*"our extractor is broken"* (an urgent defect). Both surface as `PriceNotFound`. Any replacement must
make those two separate, typed outcomes — this is a Bug-Catching-Ladder climb from *silent wrong
behaviour* to *observable typed state*.

### 3. An ISBN→URL index is *technically required*, and it is not a catalogue copy

Since search cannot resolve an ISBN (§2) and only one store addresses products by ISBN directly, a
per-ISBN price lookup is **impossible without a local map from ISBN to that shop's product URL.** The
index is not an efficiency choice; it is the only thing that makes per-ISBN lookup work at all.

Measured per-store ISBN availability (n=50 products from each store's own product API, so all stocked):

| Store | Platform | `handle` | `sku` | `barcode` | free-text body | Per-ISBN lookup possible? |
|---|---|---|---|---|---|---|
| exclusivebooks | Shopify | **50/50** | 50/50 | 0/50 | 0/50 | ✅ **direct** — `/products/<isbn>.js` → 200, 404 if unstocked |
| booklounge | WooCommerce | — | **30/30** | — | — | ✅ **native search** — `?search=<isbn>` → exactly 1 correct hit |
| bridgebooks | Shopify | 37/50 | 49/50 | 0/50 | 0/50 | ⚠️ index needed (handle contains but ≠ ISBN → 404) |
| stellenboschbooks | Shopify | 0/50 | **50/50** | 0/50 | 0/50 | ⚠️ index needed |
| wordsworth | Shopify | 0/50 | 46/50 | 0/50 | 0/50 | ⚠️ index needed |
| clarkesbooks | Shopify | 0/50 | 0/50 | 0/50 | **35/50** | ⚠️ index needed, ISBN only in prose |
| ikesbooks | Shopify | 0/50 | 0/50 | 0/50 | 0/50 | ❌ **no ISBN anywhere in 50 products** |
| lovebooks | WooCommerce | — | 0/30 | — | — | ❌ no ISBN in `sku` |
| loot, fortunatefinds | — | — | — | — | — | ❌ no product JSON API |

**WooCommerce is better than Shopify here**: its Store API `?search=` *does* match `sku`, so booklounge
needs no index at all. Two stores (`exclusivebooks`, `booklounge`) support true stateless per-ISBN
lookup today. Four need an index. Four cannot be done by ISBN at any price.

**What the index retains, and why that respects the owner's constraint.** The owner's instruction is
explicit: *"we don't want to scrape everything from a website… we aren't aiming to replicate their entire
catalog on this site."* The index honours that by retaining **only a pointer**, and only for ISBNs we
already hold:

```
build:   paginate /products.json  (transient, in memory, never persisted)
filter:  keep only records whose extracted ISBN ∈ our book_editions
retain:  (store_id, isbn, product_path, isbn_source, seen_at)     ← a pointer, ~60 bytes
discard: titles, descriptions, cover images, prices, everything else from the sweep
```

No title, no description, no image, no price is persisted from the sweep. Price comes from a **separate
per-ISBN fetch of only the editions we hold**. So we never hold a copy of their compilation — which is
also precisely what the compilation-copyright analysis in the literature section asks for. The sweep is
the equivalent of a search engine learning where a page lives; the substance is fetched per-item, on
demand.

Pagination is confirmed (`?limit=250&page=N`: clarkesbooks and bridgebooks each return 250 on page 1
*and* page 2), so the sweep is ~`shop_size/250` requests — roughly 20 per shop, on a weekly cadence, not
nightly.

### 4. ISBN extraction is per-shop, and the ladder already has its last rung built
Prices and titles come back reliably; **ISBNs do not** (§3 table). A universal extractor needs a
per-record ladder: `handle` if ISBN-shaped → `variants[].barcode` → `variants[].sku` → regex
`97[89][0-9]{10}` over the body → **else** title+author match with a confidence floor.

**That last rung already exists**: `Stacks.Books.CandidateScorer.pick_best/3` does exactly this fuzzy
title/author match with a plausibility floor (`@default_floor 2.5`, waived on author-surname
corroboration), is unit-tested, and has an offline eval harness (`mix eval.resolver`) that replays a
corpus through the *same* production seam. Reuse it; do not invent a second matcher. And note what the
table implies: for `ikesbooks` and `lovebooks` this fuzzy rung is not a fallback, it is **the only**
available path — which is exactly the case that needs the eval harness before it is trusted.

### 5. Price grain is per-edition, confirming decision D3
The Exclusive Books match for "name of the rose" returned ISBN `9780749397050` — **a different edition**
than the `9780156001311` searched for. Shops stock whichever edition they stock. So a price is
inherently a fact about an **edition**, not a work, which means **`op.price_snapshots.book_id` is the
wrong grain** and should be `book_edition_id` — the same correction D3 already applied to placements and
marketplace listings. **The table is empty, so this is the cheapest possible moment to re-key it.**

---

## Proposed architecture (final)

### The governing constraint: "will these sites always be Shopify?" — no, and nothing may assume it

This owner question is the one that should drive the design, because the honest answer changes it. A
one-person bookshop replatforms — WooCommerce → Shopify, Shopify → Wix, a theme change that moves the
ISBN out of `sku`. When that happens to a design that stores `platform = "shopify"` as hand-authored
config, every lookup silently returns nothing, and nothing distinguishes it from "not stocked" (§2).

**So platform is not configuration. It is a timestamped observation, always re-derived.**

```
capability_probe(store) →                       # 2 cheap requests, weekly + on N consecutive misses
  { price_source:  :shopify_products_json | :woo_store_api | :jsonld | :llm | :none,
    isbn_location: :handle | :sku | :barcode | :body | :fuzzy_title | :none,
    lookup_mode:   :direct | :native_search | :local_index,
    probed_at:     ~U[...] }
```

Three consequences, each of which removes a failure mode rather than handling it:

1. **A replatform cannot produce a stale config**, because there is no config to go stale. It produces a
   new observation, and at worst one cycle of `:none` before the next probe.
2. **It deletes the `scraper_module` string coupling.** Today `TriggerPriceScrapeJob` resolves a store to
   a Rust adapter via `store.scraper_module || store.name` matched against a *path-derived* registry key
   (`"za/exclusive_books"`), with **nothing validating that the two stay in sync** — a hand-maintained
   coupling between a DB column and a filename. Derived capability has no string to keep in sync.
3. **It gives the probe somewhere to assert.** The probe carries a **canary**: a known ISBN that must
   still resolve at that store, with a price of a plausible shape. Canary fails → re-probe → new
   capability, or an explicit `:none` with a reason. This is the fourth drift signal from the literature
   section, and it is what turns a replatform from a silent outage into a logged state change.

`op.discovered_sources.config_generated` (jsonb, **no writer anywhere in the codebase today**) is the
natural home for this record — a designed-but-unwired column that this work would finally connect.

### The acquisition spine

Per data type, because they have genuinely different economics — this is the correction to thinking of
this as "the scraper":

| Data | Volume | Mechanism | LLM in request path? |
|---|---|---|---|
| **Prices** | 200 editions × 8 stores | Capability-routed: direct → native search → local index | **No** — structured JSON already |
| **Edition discovery** | per work, on demand | **Open Library** work→editions (see below) | No |
| **Bookstore events** | ~a handful/month × 12 venues | `schema.org/Event` → `.ics` feed → **LLM per page** | **Yes, and correctly so** |
| **Author activity** | per followed author | RSS/Atom — `elixir_feed_parser`, already built | No |
| **Reviews** | per book | ⚠️ see *Reviews are the weak link* below | — |
| **Source/venue discovery** | slow | Brave/SearXNG + LLM scoring, already built | Yes, already |

### Edition discovery comes from Open Library, not from shop catalogues

The owner's second requirement — *"become aware if new variations on the title (different ISBNs) become
available"* — cannot be served by per-ISBN lookup, because you don't yet know the ISBN. It looks like it
forces catalogue enumeration. It does not:

```
book (work) → OL /isbn/<seed>.json → work key → OL /works/<key>/editions.json
```

**Verified:** `9780156001311` → work `OL8996439W` → **151 editions, 76 distinct ISBN-13s**.
`9780099590088` (Sapiens) → `OL17075811W` → **86 editions, 73 distinct ISBN-13s**.

So the authoritative edition list comes free from the bibliographic source **this project already trusts
as its ISBN hard gate** — no scraping, no compilation-copyright exposure, and it reuses `ISBNResolver`'s
existing cache, fuse and cascade. New OL editions become *candidate* `book_editions`; shop availability
is then a separate, lazy per-ISBN question.

⚠️ **But do not probe all of them.** 76 editions × 8 stores = 608 requests for a single work. The
edition set must be filtered before it reaches the price layer — editions we hold, plus editions someone
has expressed interest in — never the full OL fan-out. This is the one place this design could
accidentally become expensive, and it needs an explicit cap.

### Prices are pulled lazily, which deletes the nightly-batch problem

The current design's cron would issue ~2,400 requests/night at 10 req/min/store ≈ **20 hours**, for
prices nobody may look at. Instead: **fetch on demand at read time, with a staleness TTL** — the shape
`Prices.stale_isbns(7)` already implies. A price is only worth having when someone is looking at that
book. This also means the rate-limit danger of the twelve seeded targets never materialises, because
load is proportional to actual reader interest rather than to catalogue size × wall-clock.

### Where the LLM belongs — and where it does not

**Not in the price path.** Tiers 1–2 return structured JSON; an LLM there is pure cost for no gain, and
the literature is unambiguous that per-request LLM extraction is the expensive, slow, non-deterministic
option. Three legitimate roles:

1. **Configuration-time wrapper induction** (the academic name — Kushmerick 1997; "self-healing scraper"
   commercially). Given one sample page, *generate* the extraction rule once; cache it as deterministic
   commands; **validate the cached rule against the live page before executing**; re-invoke the LLM only
   on validation failure. Cost is per-site-per-change, not per-request. Copy Stagehand's caching shape.
2. **Events**, per page — appropriate precisely *because* volume is tiny (§ literature). There is no
   `/products.json` for events and Eventbrite/Meetup's open discovery APIs are retired, so after
   `schema.org/Event` and `.ics` there is nothing else. This is the one place per-page LLM extraction is
   the right call rather than a compromise.
3. **Residual title→work matching**, only if `CandidateScorer` proves insufficient on the eval corpus —
   and `ikesbooks`/`lovebooks` are the cases that will decide it.

Non-negotiables for any LLM tier: **never raw HTML** (Markdown/JSON-LD-subset pruning first — 80–90%
token reduction), a strict output schema, routed through `Stacks.AI.BudgetTracker` (which
`TogetherClient` does **not** currently use — cost tracking today is vision-only), built on
`TogetherClient.complete/2`, and gated on the `mix eval.*` corpus discipline
`notes/phase-portfolio-plan.md:17-22` requires. Same bar the vision work is held to.

### Reviews are the weak link and should be re-scoped, not built

`review_snapshots` and `FetchReviewsJob` exist but the fetcher is **mock-only — no real HTTP client was
ever written**. Before one is: GoodReads retired its public API in 2020, is Amazon-owned, and defends
aggressively; scraping it is the highest-ToS-risk item in this whole design and the literature's
contract-law finding (liability follows *accepted terms*, so never log in) bites hardest there. Open
Library exposes ratings via a real, sanctioned API. **Recommend: re-scope US-2.1.1 to sanctioned sources
before writing any review fetcher.** This is a decision to surface, not one to take unilaterally.

### ⛔ Hard rule: robots.txt stops the scrape — and three code paths violate it today

**Owner's rule (2026-07-27), stated precisely:** if robots.txt disallows the path we want, **stop there**.
Do not try another path, do not fall back to a different tier. **Keep the configuration in place** — if
the disallow is ever lifted, scraping resumes automatically without anyone re-authoring anything.

That phrasing has a specific design consequence: `robots_blocked` is a **state of the store**, not a
deletion of its config. Record `{blocked_path, matching_rule, observed_at}`, re-check on the capability
probe cadence, and resume by itself when the rule disappears. Config retention and execution gating are
separate concerns — which is also exactly what makes the rule cheap to obey.

Verified robots.txt posture across the targets:

| Site | `Disallow: /search` | `Disallow: /products.json` | `Crawl-delay` |
|---|---|---|---|
| **exclusivebooks.co.za** | ⛔ **yes** (lines 43, 111) | no | ⛔ **10s** (lines 77, 123) |
| wordsworth, clarkesbooks, bridgebooks, stellenboschbooks, booklounge, lovebooks | no | no | none declared |

**Exclusive Books is the only target that restricts anything — and the existing TOML scrapes exactly the
one path it forbids** (`search.path = "/search"`), while the JSON API it permits goes unused. The
original design was not merely broken (§2); it aimed at the single disallowed path in the entire target
set.

**Three violations of this rule exist in the code right now:**

1. ⛔ **`DiscoverBookstoreEventsJob` performs no robots.txt check at all.** It builds
   `{website_url}/events` and fetches it with `Finch.build(:get, url, …)` directly
   (`discover_bookstore_events_job.ex:68-74`) — no robots check, no rate limiter, no circuit breaker, no
   `Crawl-delay`. This is a **second, parallel scraping path** that bypasses every safeguard the Rust
   service implements.

   ⚠️ **Correction:** an earlier draft of this document said it "is live in a cron." **It is not.**
   Verified against `config.exs`'s full `crontab` list — the job is absent, and it has no enqueue site
   anywhere. So this is a **latent** violation, not an active one: nothing is being scraped
   non-compliantly today. That lowers the urgency but not the importance, because **D7 wires this job
   up** — so the compliant egress must exist *before* it is connected, not after. Sequenced into Wave 0d
   rather than treated as an emergency.
2. 🟧 **`respect_robots_txt` is a per-site overridable boolean** (`config.rs:67`, read at
   `scraper.rs:91`). A hard rule that a config file can switch off is not a hard rule. Ladder climb:
   **delete the flag** so compliance is impossible-by-construction rather than default-true. (Test
   fixtures set it `false`; they should use the `self.mock` seam already checked alongside it at
   `scraper.rs:91`, so no test coverage is lost.)
3. 🟧 **`Crawl-delay` is intentionally ignored** (`robots.rs:85-86`, "rate limiting is enforced" by the
   TOML instead). Exclusive Books declares `Crawl-delay: 10` — i.e. 6 req/min — while the TOML is free to
   declare more. Under "respect robots.txt", **a declared `Crawl-delay` must win whenever it is stricter
   than our own configured rate.** The comment is a reasonable design note that this rule now overrides.

Additionally, worth deciding deliberately rather than inheriting: `is_allowed` treats **any** failure to
fetch robots.txt as permission (`robots.rs:36-37`, "If robots.txt is unavailable, scraping is permitted").
RFC 9309 §2.3.1.4 distinguishes these — 4xx *does* mean allow-all, but **5xx SHOULD be treated as a
complete disallow.** `kalkbaybooks.co.za` returned **503** during this very probe, so the case is real,
not hypothetical.

### Per-site config becomes almost nothing

Not selectors, and not a platform name. Just: base URL, rate limit, robots posture, an optional canary
ISBN, and `bulk_index_allowed` (default **false**). Everything else is derived by the capability probe
and stored as an observation. Eleven TOMLs become one table and one probe.

---

---

## Literature review findings (2026-07-27) — and one that contradicts my own recommendation

### ⚠️ robots.txt makes the original design doubly wrong
`exclusivebooks.co.za/robots.txt` **disallows `/search`** (and filtered `/collections`) but does **not**
disallow `/products.json` or `/products/<handle>.js`. So the TOML approach was scraping **the one path
robots.txt forbids**, while the JSON API is the path it explicitly leaves open. The original design was
not just technically broken — it was the less compliant of the two options.

Confirmed independently: on that store `handle == variant.sku == ISBN-13` for most titles, so
`GET /products/<isbn>.js` addresses a product **directly by ISBN**. That is a cleaner per-ISBN lookup
than any search endpoint.

### ✅ RESOLVED — bulk catalogue ingest is legally *more* exposed than per-ISBN lookup
This cut against an earlier draft of §3. **The owner resolved it on 2026-07-27:** *"we don't want to
scrape everything from a website… we aren't aiming to replicate their entire catalog on this site."*
§3 is now written to that constraint — pointer-only retention, filtered to ISBNs we already hold, with
`bulk_index_allowed` defaulting to false. The legal reasoning below is retained because it is *why* the
constraint is right, not merely a preference:
- The EU **sui generis database right** (Directive 96/9/EC) can attach to a systematically compiled
  catalogue even where the individual facts (a price) are not protectable.
- **South Africa's Copyright Act** protects *compilations* — replicating a shop's whole catalogue could
  be an infringing reproduction, independent of the prices themselves.
- Both point the same way: **targeted, on-demand, per-ISBN lookups are more defensible than
  bulk-harvesting an entire site's catalogue.**

**Resolution — take the efficient transport and the defensible retention.** Since `/products/<isbn>.js`
exists on Shopify, prefer **direct per-ISBN fetches** where the handle-is-ISBN convention holds. Where
it does not, paginate `/products.json` **but retain only records matching ISBNs already in our
catalogue and discard the rest unpersisted** — we never store a copy of their compilation, only prices
for books we already hold. Record the choice per site as
`bulk_catalog_harvest_allowed` vs `per_isbn_lookup_only`, defaulting to the latter.

### Liability sits in contract law, not the CFAA — so stay logged out
**hiQ v LinkedIn** (9th Cir. 2019, reaffirmed 2022) held that scraping *publicly accessible* data does
not violate the CFAA — but the case ended in a consent judgment where hiQ **conceded it had breached
LinkedIn's User Agreement**. Liability landed on contract, and that hinged on hiQ having *accepted* a
ToS by logging in.

**Hard rule for this scraper: never create an account, never log in, never accept a click-through ToS
on a target site.** That keeps us outside the exact fact pattern. Also: SA's **Cybercrime Act 19 of
2020** criminalises bypassing security measures — never defeat a CAPTCHA, login wall, or WAF challenge.
POPIA exposure is low **by design** only as long as the extractor is scoped to price/ISBN/availability
and never captures reviewer names or staff bios present on the same page.

### The LLM pattern has a name and a 1997 lineage
What vendors sell as "self-healing scrapers" is **wrapper induction** (Kushmerick, 1997) with an LLM
substituted for the classifier that learns the wrapper. That matters: it is a well-understood problem
with a known shape, not a novel bet.

The concrete production model to copy is **Stagehand's caching**: resolve via LLM once, cache as plain
deterministic commands, **validate the cached selector against the live page before executing**, and
silently re-invoke the LLM only when validation fails — reported ~80% speedup across two runs because
most runs hit the cache. Kadoa adds the right promotion gate: **confidence-score new output against
historical extractions before trusting it.**

**Four drift signals to implement** (vendor-independent): (1) schema/type failure — ran but price is
null/wrong type; (2) selector-miss — resolves to zero elements; (3) statistical anomaly — value far
outside that SKU's history (R0, or a 100× jump); (4) canary assertion — a known-stable page checked on
a schedule.

### Never feed raw HTML to an LLM
Measured reductions: raw HTML → Markdown is **80–90% fewer tokens** (one cited case: 16,180 → 3,150).
Boilerplate removal alone cuts 30–50%; extracting only the JSON-LD block or a known DOM subtree cuts a
further 50–95% on top. Tooling worth reusing rather than building: **trafilatura** (pure heuristic,
~14–22ms/page, no ML, competitive with neural extractors per SIGIR 2023), **Crawl4AI** (open source,
local LLMs via Ollama), **Firecrawl** (AGPL core self-hostable — but its anti-bot layer is cloud-only,
and AGPL's network clause needs checking before shipping).

### JSON-LD is a decent Tier 2, not a foundation
Web Data Commons (the only rigorous source): ~10% of ~98B extracted n-quads relate to schema.org
Product; within offers, 95% have a name but coverage falls off fast beyond the minimum. Google's
Merchant Center requirements are what drive adoption. Real, documented failure modes: **price on the
variant rather than the top-level Product** (open Shopify community thread), **missing
`priceCurrency`** (open WooCommerce issue, May 2025), and **multiple Products per page** — so always
select the `Product` block whose `sku`/`gtin`/`url` matches the ISBN requested, never "the first one".

### Events invert the economics — LLM-per-page is *correct* there
There is **no `/products.json` equivalent for events**. Eventbrite's public discovery search was removed
in Feb 2020; Meetup's open REST API is retired behind Meetup Pro + OAuth. So the realistic cascade is
**`schema.org/Event` JSON-LD → an ICS/iCal feed → LLM extraction from a prose events page.**

And crucially: a handful of events per month across ~12 venues is *low volume*, so the cost and latency
objections that rule out per-request LLM extraction for pricing **do not apply**. Weekly poll, LLM per
page, fixed `{title, startDate, endDate, location, description, ticketUrl}` schema. Small venues running
WordPress with an events plugin get `schema.org/Event` for free; those using Google Calendar often expose
a `.ics` — the cleanest structured path of all for a one-person shop.

### Rate-limit etiquette
Cited baseline for small sites: **~1 request every 10–15 seconds**, honour declared `Crawl-delay`, back
off hard on 429/403, and identify with a descriptive User-Agent carrying a contact URL. Several targets
are one-person shops; this is not merely politeness.

## "Is there anything else?" — answered by the requirements survey

The owner asked what else we want besides prices and events. **Five distinct acquisition modes are
already storied, not one** — and treating this as "the scraper" is itself part of the design error:

| Data | Story | Mechanism | Status in code |
|---|---|---|---|
| Prices | US-2.2.1 | Per-ISBN, capability-routed | Broadway pipeline built; fetcher wrong (§2) |
| Bookstore events | US-2.4.1 | JSON-LD `Event` → `.ics` → LLM | Built, but via **raw regex** and no robots check |
| Author activity | US-2.3.1 | RSS/Atom feeds | Built — `elixir_feed_parser`, genuinely fine |
| Reviews | US-2.1.1 | ⚠️ re-scope (see above) | **Mock-only — no real client exists** |
| Source/venue discovery | US-2.5.1/2/3, US-3.1.1 | Brave/SearXNG + LLM scoring | Built; `third_spaces` is **Phase 4**, not Phase 2 |

Deferred but on the roadmap, and worth *not* designing against yet: Readables (Crossref / arXiv /
Semantic Scholar / OpenGraph — Phase 7, needs its own ADR per `notes/product-ideas.md:154-156`),
catalogue import (Goodreads CSV, Audible, Bookshop.org — file import, not scraping, but still funnels
through the ISBN gate), and Gutenberg full text for the writing assistant (Phase 7).

**Design consequence:** the events path is *not* a special case of the price path. Different volume,
different structure, different tier. Build one **acquisition spine** (capability probe → robots gate →
rate limiter → fuse → typed outcome → event emission) with **small per-data-type extractors** hanging off
it. The current codebase has the opposite: two unrelated spines (Rust service, and a bare `Finch` call in
an Oban job) with the safeguards on only one.

### Reusable infrastructure — build on these, do not reinvent

The survey found more already built than expected. Anything new should compose with:

- **`CandidateScorer.pick_best/3`** — fuzzy title/author match with plausibility floor; the last rung of
  the ISBN ladder, and the *only* path for `ikesbooks`/`lovebooks`.
- **`ISBNResolver.search_by_title/4`** — an existing query-broadening cascade (exact → enriched →
  subtitle-stripped → title-only), plus two-tier ETS+Postgres caching and per-provider fuses. Edition
  discovery slots straight into this.
- **`mix eval.resolver`** — corpus file + pure production seam + non-zero exit on regression. Any new
  extractor should copy this shape rather than invent an eval mechanism.
- **`CircuitBreakers`** — probe-based recovery, already has `:scraper_fuse` (3 failures/60s → 15min).
  Note per-store fuses are explicitly deferred (`circuit_breakers.ex:21`); with 12 stores that deferral
  should be revisited, since one dead shop currently opens the fuse for all of them.
- **`TogetherClient.complete/2`** — the only generic LLM completion path. `AI.Client` is vision-only.
- **`BudgetTracker`** — but note it is wired to **vision only**; `TogetherClient` and `ScraperClient`
  bypass it entirely. Any LLM tier here must route through it.
- **`PricePipeline`'s "one event per batch, not per row"** persistence contract — the pattern to copy.

⚠️ **Schema changes go through proto, not migrations.** All eight candidate tables are proto-generated
(`proto/persisted.exs` → `mix proto.sync`); the Ecto modules under `lib/stacks/gen/` say DO NOT EDIT and
`mix proto.sync --check` fails CI on drift. Re-keying `price_snapshots` means editing
`stacks/common/v1/enrichment.proto`, not writing a migration by hand.

## Immediate implications for the campaign plan
1. **Do not write the eleven TOMLs.** The schema is wrong and the abstraction is wrong. Two platform
   adapters plus a capability probe replace all of them.
2. **Delete `respect_robots_txt`** and honour `Crawl-delay` — the owner's hard rule, currently
   config-overridable and partly ignored.
3. **Route `DiscoverBookstoreEventsJob` through the acquisition spine or delete it.** Today it scrapes
   with no robots check, no rate limit and no fuse, from a cron.
4. **Re-key `price_snapshots` to `book_edition_id` now**, while it is empty (D3 consistency) — via proto.
5. **Make "not stocked" a typed outcome**, distinct from "extractor broken" (§2). This is the highest-value
   ladder climb in the whole area.
6. **`TriggerPriceScrapeJob` becomes lazy/TTL-driven**, not a nightly sweep — which also disposes of the
   20-hour batch and the rate-limit danger of the seeded targets.
7. **Cap the OL edition fan-out** before it reaches the price layer (76 editions × 8 stores per work).
8. **Re-scope reviews (US-2.1.1) to sanctioned sources** before any fetcher is written.
9. `kalkbaybooks` (503 — note RFC 9309 treats 5xx as full disallow) and `skoobs` (connection error) need
   re-probing; `loot`, `fortunatefinds`, `ikesbooks`, `lovebooks` have **no viable per-ISBN path** and
   should be recorded as such rather than configured hopefully.
