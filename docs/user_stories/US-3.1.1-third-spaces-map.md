# US-3.1.1 — Find Somewhere to Read (Third Spaces Map & Cork Board)

> **Status:** DRAFT for owner review, 2026-07-28. Written because the story was referenced
> by `implementation-mapping.md` (Phase 4, and depended on by Phase 3) but **no story file
> existed**, so it could not be built to spec. Owner has proposed promoting it into Phase 1.
> Open decisions are marked **⚠️ DECIDE** and gathered at the end.

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

⚠️ **DECIDE:** confirm the list, and whether the reader can filter by category or the platform
picks. Recommendation: filter by category — a reader who wants a quiet garden and one who wants a
noisy pub are both served, and it is cheap once the tags are there.

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

`Discovery.approve_source/1` promotes a source to `approved` but does **not** create a third
space. ⚠️ **DECIDE:** does approving a space-like `discovered_source` create the `third_space`?
Recommendation: yes, and **only** via approval — these are real businesses, and listing one
unreviewed is precisely the harm US-2.5.3 exists to remedy.

### ⚠️ DECIDE — where "well-regarded" comes from

The hardest open question, because the obvious source is encumbered:

| Option | Cost | Constraint |
|---|---|---|
| **Google Places ratings** | Paid per request | Terms restrict caching and generally require Google's own map alongside — which conflicts with self-hosted tiles |
| **Rank by what we have** | Free | Proximity to a bookshop, count of upcoming events, whether any user has placed a book there. Defensible and honest, but not "well-regarded" |
| **Readers rate spaces** | Free | A feature in its own right (auth, moderation, abuse) — and cold-start empty |
| **Owner curates** | Free | Does not scale past one city, but is *accurate*, and matches the "small posters" framing |

Recommendation: **owner-curated for the launch city, ranked by our own signals elsewhere.** The
cork board shows "a handful", not a leaderboard — curation suits that, and it avoids both a paid
dependency and a cold-start rating system. Revisit if the map goes wide.

---

## 5. Architecture decisions this forces

### ⚠️ DECIDE — an Elm port

`CLAUDE.md` says *"No ports unless absolutely necessary."* An interactive map is JavaScript
(MapLibre GL or Leaflet); there is no Elm-native equivalent at this quality. This is the
canonical necessary case, but it should be an explicit decision rather than discovered
mid-build, because it is the project's first port and sets a precedent.

Recommendation: **one narrow port**, with the JS side owning only camera state and pin rendering,
and every decision (what to fetch, what to show, what a pin means) staying in Elm. The port
carries a viewport out and a pin list in — nothing else.

### ⚠️ DECIDE — map tiles and the CSP

The CSP is deliberately strict. Options: **self-hosted tiles** (no CSP change, no third party,
costs storage and a rendering pipeline) or a **hosted provider** (one `img-src`/`connect-src`
addition, a third-party dependency, possibly a key).

Recommendation: **hosted provider to start**, with the CSP addition made explicitly and the
provider recorded in an ADR. Self-hosting tiles is a project of its own and should not gate this.

### Geospatial queries

`op.third_spaces` needs `latitude`/`longitude`, and so does `op.bookstores`. Both are
proto-generated, so this is a `.proto` + `persisted.exs` + `mix proto.sync` change.

⚠️ **DECIDE:** plain lat/lng columns with a bounding-box query, or PostGIS. Recommendation:
**plain columns + bounding box**. A viewport *is* a bounding box, the 500 m rule can be a
Haversine expression, and PostGIS is an extension dependency (and a Neon consideration) that buys
nothing until we need real geometry.

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
