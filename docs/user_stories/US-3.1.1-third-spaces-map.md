# US-3.1.1 — Find Somewhere to Read (Third Spaces Map & Cork Board)

> **Status:** SPECIFIED, 2026-07-28. Written because the story was referenced by
> `implementation-mapping.md` (Phase 4, and depended on by Phase 3) but **no story file existed**, so
> it could not be built to spec. Owner has proposed promoting it into Phase 1.
>
> All six open decisions were resolved on 2026-07-28 and are recorded inline as **✅ DECIDED**, with
> their consequences written into §7's definition of done. Two carry ⚠️ warnings that survive the
> decision: the "well-regarded" source is the most likely to be revisited (§4), and the tile branch
> turns on a terms-of-service reading that must precede the build as an ADR (§5).
>
> **One thing this story cannot decide for itself:** it is a Phase 4 story, and three of its four data
> inputs do not exist. See the sequencing note in §8 — specifying it does not make it Phase 1 work.

## 1. User Story

> **As a** reader, **I want to** see where I can go and read near me — and what bookish things
> are happening there — **so that** I can leave the house with a book and know where I am going.

The page splits in two. On the **left**, a searchable map. On the **right**, a cork board of
up-and-coming bookish events and small posters for well-regarded third spaces. The two are
coupled: the cork board always describes the part of the world the map is showing.

The map opens on the reader's broad location, inferred from their IP — Cape Town, say, not their
street. It highlights **third spaces within 500 m of a bookshop**, because the pairing is the
point: somewhere to buy a book and somewhere to sit with it. A reader can zoom into a
neighbourhood (Observatory), search a place by name, or drag across the globe to Shanghai — and
the map re-filters to that view, with the cork board following.

A third space is somewhere you can plausibly sit and read that is neither home nor work.

---

## 2. What they see on the page

### Happy path
1. Reader opens `/third-spaces` from the main navigation.
2. The map centres on their inferred city at neighbourhood-ish zoom. A brief, dismissible note
   says how the location was guessed and offers a search box — the guess is never presented as
   certain.
3. Pins render for third spaces **within 500 m of a bookshop**. Bookshops render distinctly, so
   the pairing is legible rather than implied.
4. The cork board shows, for the current view: **up-and-coming events** (soonest first) and **a
   handful of well-regarded third spaces** as small posters.
5. Reader pans to Shanghai. The map re-queries; pins and cork board both refresh to that view.
6. Reader zooms into one neighbourhood. Same again, narrower.
7. Reader clicks a pin: a card with the space's name, type, why it is listed (near which
   bookshop), and any upcoming events there.
8. Every listing carries a discreet **"Is this your business?"** link (US-2.5.3).

### Sad paths
- **IP location unavailable or implausible** — map opens on a documented default rather than
  guessing wildly, with the search box focused. Never a blank map.
- **No third spaces in view** — the map says so plainly and suggests zooming out. The cork board
  says the same. Neither shows a spinner forever, and neither shows pins from elsewhere.
- **No bookshops in view** — the 500 m rule cannot be applied, so the map explains that this
  area has no bookshops on record yet and offers the opt-in to suggest one. This is expected for
  most of the globe at launch and must not read as an error.
- **Events absent but spaces present** — cork board shows posters only. The reverse also holds.
- **Map tiles fail to load** — pins and cork board still render over a plain background. The
  reader's answer is "where can I read", and a tile outage should not withhold it.
- **Reader declines location** — identical to unavailable. No nagging.

---

## 3. What counts as a third space

Filterable, and every category below maps to an OpenStreetMap tag so no bespoke data entry is
required:

| Category | OSM tag | Why |
|---|---|---|
| Café | `amenity=cafe` | The archetype |
| Restaurant | `amenity=restaurant` | Owner-specified |
| Bar / pub | `amenity=bar`, `amenity=pub` | Owner-specified |
| Park | `leisure=park` | Owner-specified |
| Garden | `leisure=garden` | Botanical gardens are among the best reading spots and are not parks |
| Library | `amenity=library` | Obvious, and a natural bookshop neighbour |
| Museum | `tourism=museum` | Cafés and benches, quiet by convention |
| Square / plaza | `place=square` | The European reading bench |
| Beach | `natural=beach` | Cape Town, Durban — locally essential |
| University campus | `amenity=university` | Lawns and open seating |
| Community centre | `amenity=community_centre` | Where reading groups already meet |

**Deliberately excluded:** hotels and shopping centres. Readable in principle, but including them
dilutes "third space" into "indoor seating with a chair", which is not what a reader is looking
for.

### ✅ DECIDED (2026-07-28) — the list above stands, and the reader filters

Category filters are exposed to the reader. A reader wanting a quiet garden and one wanting a noisy
pub are looking for opposite things, and the platform cannot guess which; once the OSM tags are
stored the filter is a `where type in (…)` clause, so it is close to free.

Two constraints on the filter, both of which are the difference between a filter and a trap:
- **Filters narrow the map *and* the cork board**, because the two are coupled (§1). A filter that
  changed only the pins would leave posters for spaces the reader just excluded.
- **The 500 m-of-a-bookshop rule is not filterable.** It is the premise of the page, not a
  preference. A reader who turns it off is using a general-purpose map, which this is not.

---

## 4. Data this needs, and what is missing

This is the part that determines whether the story is Phase 1 or later. **Three of the four
inputs do not exist yet.**

| Input | State | Gap |
|---|---|---|
| Third-space locations | ❌ `op.third_spaces` has **0 rows**, and nothing writes it | A producer, and coordinates — the table has `city` but **no lat/lng** |
| Bookshop locations | ❌ `op.bookstores` has `website_url`, `country_code`, **no lat/lng** | Geocoding, without which the 500 m rule cannot be computed at all |
| "Well-regarded" | ❌ No rating exists for any space | ⚠️ **DECIDE** — see below |
| Events near a view | ❌ `third_space_events` and `bookstore_events` both **0 rows** | Needs the `schema.org/Event` → `.ics` → LLM cascade from the scraper research, and venues with coordinates first |

### The discovery chain stops short

```
user.location_updated → LocationUpdatedHandler → GeographicDiscoveryJob
                      → SourceDiscoveryJob → op.discovered_sources ✓
                                           → op.third_spaces        ✗ nothing writes this
```

`Discovery.approve_source/1` promotes a source to `approved` but does **not** create a third space.

#### ✅ DECIDED (2026-07-28) — approval is the *only* producer of a `third_space`

`Discovery.approve_source/1` creates the `third_space` row when the source's type is space-like, and
nothing else in the system may insert one. These are real businesses with real reputations; listing
one that no human has looked at is precisely the harm US-2.5.3 exists to remedy, and "we scraped it"
is not a defence a business owner will accept.

Consequences to build to, not discover later:
- **Approval needs coordinates to be useful**, so geocoding happens at approval time, not at render
  time. An approved space that failed to geocode is a real state: it exists but cannot be mapped, and
  it must not silently vanish from the owner's queue.
- **Rejection and removal are the same mechanism, reached differently.** A removal request under
  US-2.5.3 sets `opted_out` / `opted_out_at` on the `third_space`; the space stops rendering but the
  row survives, so re-approval cannot resurrect a business that asked to be delisted. See the G6
  ruling at the end of this file.
- **The producer is event-driven, not batch.** A cron that "creates rather than refreshes" is the
  exact defect class that left `discovered_sources` empty for months (campaign ROOT G). Approval is a
  human action, so it already has an event to hang from.

### ✅ DECIDED (2026-07-28) — where "well-regarded" comes from: owner-curated at launch

The hardest open question, because the obvious source is encumbered:

| Option | Cost | Constraint |
|---|---|---|
| **Google Places ratings** | Paid per request | Terms restrict caching the returned content. ⚠️ Also generally require Google's own map alongside — which is a *choice* (show Google's map), not an obstacle; see the correction below |
| **Rank by what we have** | Free | Proximity to a bookshop, count of upcoming events, whether any user has placed a book there. Defensible and honest, but not "well-regarded" |
| **Readers rate spaces** | Free | A feature in its own right (auth, moderation, abuse) — and cold-start empty |
| **Owner curates** | Free | Does not scale past one city, but is *accurate*, and matches the "small posters" framing |

**Ruling: owner-curated for the launch city, ranked by our own signals elsewhere.** The cork board
shows "a handful", not a leaderboard — curation suits that framing, and it avoids both a paid
dependency and a cold-start rating system.

⚠️ **Correction (2026-07-28).** An earlier draft said Google Places was "rejected outright" because its
terms require Google's own map alongside, "which contradicts the tile decision below". That reasoning was
circular — it contradicted a *decision made in this same document*, and the obvious answer is the one the
owner gave: put Google's map on the left of the cork board. That satisfies the requirement.

So Google is **not** ruled out on that ground. What choosing it actually costs, and what should decide it:

- **The real trade is privacy, not permissibility.** Google's map JS runs in the reader's browser, so
  every reader's IP and viewport reaches Google on every pan, and **cannot be proxied** — which is exactly
  what §5's proxy ruling was protecting. That makes Google a processor to name in the privacy policy and
  probably a consent question, and it needs CSP entries in a deliberately strict policy. ⚠️ Whether it
  needs `unsafe-eval` — forbidden outright by `CLAUDE.md` — must be checked, not assumed.
- **The caching terms are separate and survive the map choice**, because ratings would be *stored*
  alongside a space rather than fetched per render.
- **Cost scales differently.** Geocoding is per approval (rare, human-paced); map loads are per reader
  session. Those are very different volumes on a paid plan.

The ruling above stands on its own merits — curation suits "a handful", and it avoids a paid dependency
and a cold-start problem — **not** on Google being impermissible.

What this obliges:
- A **`curated` / `curated_note` field** on `third_space`, owner-writable. The note is what the poster
  says; "4.6 stars" is not a sentence a cork board should contain anyway.
- **The cork board must never imply a rating it does not have.** No stars, no scores, no "top rated"
  — the copy is editorial ("a good window seat and no music"), which is honest about its provenance
  and is also better writing.
- **Outside the launch city the ranking is our own signals** — proximity to a bookshop, count of
  upcoming events, recency — and the section is headed as *nearby*, not as *well-regarded*, because
  ranking by proximity and calling it quality would be a lie the reader can detect.

⚠️ This is the decision most likely to be revisited, and the cheapest to revisit *if* the copy never
claimed to be a rating. That is the reason for the second bullet.

---

## 5. Architecture decisions this forces

### ✅ DECIDED (2026-07-28) — one narrow port, and it is the project's precedent

`CLAUDE.md` says *"No ports unless absolutely necessary."* An interactive map is JavaScript (MapLibre
GL or Leaflet); there is no Elm-native equivalent at this quality. This is the canonical necessary
case. Recording it as a decision rather than discovering it mid-build matters because it is the
project's **first** port and every later argument will cite it.

**The contract, which is the whole point of calling it narrow:**

| Direction | Payload | Nothing else |
|---|---|---|
| Elm → JS | camera commands (`setView {lat, lng, zoom}`), and the pin list to draw | — |
| JS → Elm | `viewportChanged {north, south, east, west, zoom}`, `pinClicked <id>` | — |

Every *decision* stays in Elm: what to fetch, when a viewport change is worth a request, what a pin
means, what the cork board shows, what the empty states say. The JS side owns pixels and gestures and
holds no application state — given the same pin list it draws the same map, so it cannot disagree with
Elm about what is on screen.

Two rules that keep the precedent from being cited to justify a wider port later:
- **The port is not a data channel.** Pins reach Elm through the normal `RemoteData` API path and are
  passed *out* to JS. JS never fetches, so a tile-provider outage cannot invent or hide a listing.
- **`viewportChanged` must be debounced in Elm, not JS.** A drag across the globe fires continuously;
  the decision about how much movement justifies a query is application logic, and putting it in JS is
  how the JS side quietly grows a policy.

### ✅ DECIDED (2026-07-28) — hosted tiles, proxied through our backend if the provider's terms allow

The CSP is deliberately strict, and there is a consideration the original framing missed: **a tile
provider receiving requests directly from the browser learns each reader's IP address and exactly
where they are looking, on every pan.** For a project whose stated posture is GDPR-by-default, that is
a data-sharing decision, not a CSP line-item — and it is the reason this ruling is not simply "add the
provider to `img-src`".

**Ruling, in preference order:**

1. **Proxy tiles through our own backend** — `GET /api/tiles/:z/:x/:y`, cached. CSP stays
   `img-src 'self'` (no relaxation at all), the provider sees only our server, and no reader IP or
   viewport leaves our infrastructure. Costs our bandwidth and a cache; costs no rendering pipeline.
2. **Direct client requests** with an explicit `img-src` / `connect-src` addition — *only* if the
   chosen provider's terms forbid proxying, which is common (several providers require direct client
   calls or reserve proxying for paid tiers, and the OSM community tile server's usage policy rules out
   an application of this shape entirely).
3. **Self-hosted tile rendering** — correct long-term, a project of its own, and explicitly not a gate
   on this story.

✅ **SETTLED by ADR 022** (`docs/decisions/022-map-tiles-and-geocoding-provider.md`), written
2026-07-28 against the fetched sources rather than deferred. Branch 1 (proxy) is taken, and the CSP
therefore does **not** change — `script-src 'self'` and `img-src 'self'` both stand.

⚠️ **Google Maps is ruled out, but not for the reason this document originally gave.** Two of the
three objections dissolved on reading the terms: the caching limit does not bind us (lat/lng may be
stored **indefinitely** for end-user-facing features), and "requires a Google map alongside" was the
wrong shape of claim. What survives is a verified chain — Google Geocoding's policy requires results
*shown on a map* to be on a **Google map**; Google Maps JS requires **`'unsafe-eval'`** even in
Google's own recommended strict CSP; `unsafe-eval` is forbidden outright by `CLAUDE.md:144` and
`security.md:139`. See the ADR for the citations.

⚠️ **Still open, and deliberately so: *which* non-Google tile provider.** That turns on each
provider's own stance on proxying, which several restrict or reserve for paid tiers — and picking one
without reading those terms would repeat exactly the mistake ADR 022 exists to correct. Vector tiles
proxy less cleanly than raster, which is worth knowing before the shortlist.

### Geospatial queries

`op.third_spaces` needs `latitude`/`longitude`, and so does `op.bookstores`. Both are
proto-generated, so this is a `.proto` + `persisted.exs` + `mix proto.sync` change.

#### ✅ DECIDED (2026-07-28) — plain lat/lng columns and a bounding-box query, not PostGIS

A viewport **is** a bounding box, so the primary query is `where latitude between ? and ? and longitude
between ? and ?` — indexable, and expressible in Ecto without an extension. The 500 m rule is a
Haversine expression, which the codebase already has: `Stacks.Enrichment.haversine_km/4`
(`apps/core/lib/stacks/enrichment.ex:244`) is written and working, and is currently reduced to
uselessness only because it joins against a hardcoded six-entry `@city_coords` map instead of real
coordinates. Adding the columns makes existing code correct rather than adding new code.

PostGIS is an extension dependency and a Neon consideration that buys nothing until we need real
geometry (polygons, routing, true geodesic joins) — none of which appears in §6's non-goals.

Two things to build correctly the first time, because both are cheap now and painful later:
- **The 500 m proximity join is precomputed, not per-request.** Recomputing "is this space within 500 m
  of a bookshop" across every space in a viewport on every pan is the query that will eventually force
  PostGIS for the wrong reason. Store the nearest-bookshop distance on the `third_space` at geocode
  time; the map then filters on a scalar.
- **Antimeridian panning breaks naive bounding boxes** (`east < west` when crossing ±180°). A reader
  dragging past the Pacific is explicitly in scope per §1's "drag across the globe to Shanghai", and a
  plain `between` silently returns nothing there. Handle it as two boxes, and test it.

---

## 6. Non-goals

- Directions, transit, or routing. The reader gets a place and its name.
- Reviews or comments on spaces.
- Check-ins, or "I read here" social features.
- Partner onboarding from the map (Phase 3, per US-2.5.3's deferral).
- Global bookshop coverage at launch. The 500 m rule means the map is useful exactly where
  bookshops are known, and the sad path says so honestly rather than pretending otherwise.

---

## 7. Definition of done

- [ ] `/third-spaces` is reachable from the main navigation, split map/cork-board.
- [ ] Map opens on an IP-inferred city, with the guess disclosed and overridable by search.
- [ ] Pins show third spaces within 500 m of a bookshop; bookshops render distinctly.
- [ ] Panning and zooming re-query, and the cork board follows the viewport.
- [ ] Cork board shows soonest-first events and a handful of curated spaces for the current view.
- [ ] Category filtering works for the agreed list.
- [ ] Every sad path in §2 renders its stated message — **including the two that are the normal
      case at launch** (no bookshops in view, no events).
- [ ] Each listing carries the "Is this your business?" link (US-2.5.3).
- [ ] A third space exists **only** via an approved discovered source.
- [ ] Driven live on a preview stack: at least one real city with real pins, and one pan to a
      region with no data showing the honest empty state.

From the six decisions:
- [ ] Category filters narrow **both** map and cork board; the 500 m rule is not filterable.
- [ ] The cork board shows no stars, scores, or "top rated" anywhere — editorial copy only, and the
      non-launch-city section is headed *nearby*, not *well-regarded*.
- [ ] The port carries only camera/pins out and viewport/click in; `viewportChanged` is debounced in
      **Elm**. No fetch on the JS side.
- [ ] An ADR records the tile branch, the provider, and the terms clause consulted — **merged before
      the map is built**. If tiles are direct rather than proxied, the privacy policy names the third
      party.
- [ ] `latitude`/`longitude` on `op.third_spaces` **and** `op.bookstores`, via `.proto` +
      `persisted.exs` + `mix proto.sync` (not a hand-written migration).
- [ ] Nearest-bookshop distance is stored at geocode time, so the viewport query filters on a scalar.
- [ ] **A pan across the antimeridian returns results** — the two-box case has a test, because the
      naive query fails silently rather than loudly.
- [ ] An approved space that failed to geocode is visible to the owner as such, not silently dropped.
- [ ] A `third_space` whose business has opted out stops rendering and **cannot be resurrected by
      re-approval** (see §8).

---

## 8. Two rulings that live outside this story

### G6 — what "removed" means (US-2.5.3)

✅ **DECIDED (2026-07-28): soft-delete, using the columns that already exist.** A removal request that
passes verification sets `opted_out = true` and `opted_out_at` on the `third_space`
(`Stacks.Enrichment.third_space_changeset/2` already casts both). The row is never hard-deleted.

The reason is not sentiment about data, it is correctness: the discovery pipeline re-finds sources
continuously, so a hard-deleted business would be rediscovered, re-approved by an owner who has no
record of the objection, and re-listed — turning one removal request into a recurring one. The surviving
row is what makes the removal *stick*. It follows that:
- Approval must **refuse** to create or revive a `third_space` for an opted-out source, and
- `Discovery.record_removal_request/2`'s verified path must reach the `third_space`, not only the
  `discovered_source` — the source is how we found it; the space is what the reader sees.

Verification is already built: `email_domain_matches_source?/2` auto-applies an exclusion when the
requester's email domain matches the listing's domain, and otherwise records
`exclusion_requested_at` and leaves the status for owner review.

### Sequencing — specifying this story does not promote it

Per §4, **three of the four inputs do not exist**: no producer for `third_spaces`, no coordinates on
either table, no events, and no rating source. The gap between "the page is unrouted" (a Wave 0b wiring
fix, hours) and "the page has something true to show" (geocoding, a producer, an ADR, a port, a tile
decision) is the whole story, and routing an empty map to the navigation would be worse than leaving it
unrouted — it would present a broken promise on the main nav.

**Ruling:** the wiring stays in Wave 0b only if it lands behind the same gate as the data. Otherwise
this is its own issue, sequenced after the geocoding and producer work, and Wave 0b's G1 row is
honestly reduced to "route it *when* it has data". See `plans/staff-campaign-2026-07-27.md`.
