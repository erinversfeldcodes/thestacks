# ADR 022: Map tiles and geocoding provider for the third-spaces map

**Status:** Accepted
**Date:** 2026-07-28
**Story:** US-3.1.1 (Find Somewhere to Read — Third Spaces Map & Cork Board)
**Supersedes:** the "⚠️ DECIDE — map tiles and the CSP" placeholder in US-3.1.1 §5

## Context

US-3.1.1 puts a searchable map beside a cork board. That needs two external capabilities:

1. **Geocoding** — a place description → coordinates, at source-approval time.
2. **Tiles** — the map imagery a reader pans around.

Two rulings were recorded in the story on 2026-07-28 (proxied non-Google tiles; Nominatim
for geocoding) and both were justified **badly**. The stated reason was that Google's terms
"require Google's own map alongside, which contradicts the tile decision" — which is
circular: it contradicted a decision made two paragraphs earlier in the same document. The
owner challenged it directly: *"why does this contradict? shouldn't we be able to place
Google's map to the left of the cork board?"*

They were right that the reasoning was invalid. This ADR replaces it with the actual
constraints, read from the current sources rather than summarised from memory.

## What the sources actually say (fetched 2026-07-28)

| Question | Finding | Source |
|---|---|---|
| Must geocoded results be shown on a Google map? | **Only if shown on a map at all**: *"Geocoding API results displayed on a map must be shown on a Google Map, and attribution is required when displaying data without a Google Map."* | [Geocoding policies](https://developers.google.com/maps/documentation/geocoding/policies) |
| Can we store lat/lng permanently? | **Yes.** Temporary caching is capped at 30 days, **but** lat/lng, `formatted_address` and structured address values may be cached **indefinitely** *"solely to support direct, end-user facing functionality of the customer application that initiated the request."* Place IDs are exempt entirely. | [Maps Service Specific Terms](https://cloud.google.com/maps-platform/terms/maps-service-terms) |
| Does Google Maps JS need `unsafe-eval`? | **Yes.** Google's own *recommended strict-CSP* example is `script-src 'nonce-{…}' 'strict-dynamic' https: 'unsafe-eval' blob:`. The allowlist variant additionally needs `'unsafe-inline'`. | [Maps JS CSP guide](https://developers.google.com/maps/documentation/javascript/content-security-policy) |

**Two of my three earlier objections dissolved.** The caching limit does not bind us — our
storage is exactly the permitted "direct, end-user facing functionality" case, so
`op.third_spaces.latitude/longitude` and the derived `nearest_bookshop_km` are fine to keep
indefinitely. And "requires a Google map alongside" was the wrong shape of claim.

**One objection survived, and it is decisive** — but it is a *chain*, not a single clause.

## Decision

### 1. Geocoding: Nominatim (OpenStreetMap), behind `Stacks.Geocoding`

### 2. Tiles: a non-Google raster provider, **proxied** through `GET /api/tiles/:z/:x/:y`

### 3. Google Maps Platform is rejected — on the CSP rule, via a three-link chain

This is the whole argument, and every link is verified above:

> Use Google **Geocoding** → the coordinates are displayed **as pins on a map**, so the
> policy requires that map to be a **Google map** → Google Maps JS **requires
> `'unsafe-eval'`** in `script-src`, even in Google's own recommended strict CSP →
> `unsafe-eval` is **forbidden outright** by this project.

The prohibition is not a preference and not new:

- `CLAUDE.md:144` — *"Do Not: Use `unsafe-eval` in CSP (Elm doesn't need it)"*
- `docs/agents/standards/security.md:139` — *"Elm does NOT require `unsafe-eval`. Never add it."*
- The live policy is `script-src 'self'` (`security_headers.ex:36`) — no `unsafe-*` of any kind.

`unsafe-eval` re-enables `eval`/`new Function` for **every** script on the page, which is the
single largest XSS-severity amplifier available in a CSP. Trading it away to obtain nicer
geocoding on an approval-time batch operation is a bad exchange, and it would be paid on every
page the map shares a policy with.

⚠️ **The escape hatch, recorded so nobody re-derives it.** Google Geocoding *is* usable without
Google Maps if its results are **not displayed on a map** — attribution suffices. That is a real
option for a non-map surface (a list of places, an admin queue). It is simply not this story,
whose entire premise is pins on a map. If a future surface wants Google's accuracy without a map,
the geocoder seam already supports it.

### 4. The privacy argument is secondary here — but it points the same way

Google Maps JS runs in the reader's browser, so every reader's IP and viewport reaches Google on
every pan and **cannot be proxied**. That would make Google a processor to name in the privacy
policy and probably a consent question under the project's GDPR-by-default posture. Recorded as
corroborating rather than decisive: the CSP rule settles it on its own, and a decision resting on
one verified rule is stronger than one resting on a privacy judgement that invites debate.

## Consequences

- **The CSP does not change.** `script-src 'self'` stands. Proxied tiles keep
  `img-src 'self'`, so no relaxation is needed for the map either — the strongest form of this
  decision, since it costs nothing in the policy.
- **Geocoding accuracy is weaker than Google's** on business names. Accepted: geocoding runs at
  approval, a human is present, and an approved space that fails to geocode is already a designed,
  visible state rather than a silent loss.
- **Nominatim's usage policy binds us**: an identifying `User-Agent` and ~1 req/sec. Honoured
  structurally — geocoding is human-paced at approval, and there is deliberately **no batch
  geocoding entry point**.
- **Tile bandwidth is ours**, because we proxy. A cache is required before the map ships.
- **Swapping provider stays a config line** (`:core, :geocoder`) — but ⚠️ swapping *to Google*
  is not, because it drags in the chain above. The seam is not a licence to change provider
  without re-reading this ADR.

## Alternatives considered

| Option | Why not |
|---|---|
| **Google Maps + Google Geocoding** | Requires `unsafe-eval`; forbidden. See §3 |
| **Google Geocoding + non-Google tiles** | Violates the Geocoding display policy — results shown on a map must be on a Google map |
| **Direct (unproxied) non-Google tiles** | Cheaper for us, but leaks every reader's IP and viewport to a third party, and needs `img-src`/`connect-src` relaxations. Proxying avoids both for the price of bandwidth |
| **Self-hosted tile rendering** | Correct long-term, a project of its own, and explicitly not a gate on this story |
| **Self-hosted Nominatim** | Removes the rate-limit and User-Agent constraints. A config change (`:nominatim_base_url`) when volume justifies it — deliberately not now |

## Open items this ADR does *not* settle

- **Which** non-Google tile provider. Deferred on purpose: it turns on that provider's own terms
  regarding proxying, which several restrict or reserve for paid tiers, and picking one without
  reading them would repeat the mistake this ADR exists to correct. ⚠️ **Vector tiles proxy less
  cleanly than raster** — worth knowing before the shortlist.
- The tile cache's storage budget and eviction policy.
