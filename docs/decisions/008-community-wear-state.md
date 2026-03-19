# ADR 008: Community-Driven Wear State on Looking for a Home

**Status:** Accepted
**Date:** 2026-03-17
**Deciders:** Platform owner
**Technical area:** Data model, UX, community signals

---

## Context

Book spines on The Stacks render with a visual wear level: `Pristine | Softened | Cracking | WellRead | WellLoved`. This wear level drives the spine's visual appearance (cracking leather texture, faded title, dog-eared bookmark icon) and communicates a book's relationship to readers.

For books on the owner's personal bookshelves (Library, AntiLibrary, WishList, ReadingPile), the wear level is straightforward — it reflects the owner's relationship to that book: how many times they've read it, how long they've had it.

**The challenge: Looking for a Home**

Looking for a Home is the seller's bookshelf — books the owner is rehoming. These books are being listed to *other* platform users. The wear display question: whose relationship should it reflect?

**Option A — Owner's personal wear history:**
The spine shows how worn the owner's copy is. Relevant to the buyer (condition), but private — it reveals the owner's reading habits and how many times they've read this specific copy.

**Option B — Community aggregate wear:**
The spine shows aggregate read/engagement signals from the entire platform community: how many users have this book in their Library, how many have finished it, community rating aggregates. This is `mart_community_read_count` from the dbt pipeline.

**Option C — Explicit condition grading:**
The seller assigns a condition (`new | like_new | good | fair | poor`) at listing time. Spine renders from this rating. This is the marketplace standard (eBay, ThriftBooks).

The design intent for Looking for a Home is that it functions as a *social signal* — not just a personal archive — and the wear state should communicate the book's cultural resonance to potential buyers, not just its physical condition.

**Community wear is not personal history:** The community engagement signal (how loved this book is across the platform) is distinct from the owner's personal reading count. A well-loved community book might be freshly purchased by the seller. A personally well-read book might be obscure with little community signal.

---

## Decision

**The Looking for a Home bookshelf uses community-driven wear state, derived from `mart_community_read_count`. The seller provides an explicit condition grade at listing time (separate from wear display).**

**Community wear derivation:**
The wear level displayed on Looking for a Home spines is computed from `wh.mart_community_read_count` — a dbt mart that aggregates, per work:
- Total platform users who have this book in Library (have read it)
- Total platform users who have moved it to Library from Reading Pile (completed it)
- Average personal rating across all platform users who have rated it

The wear mapping is approximate:

| Community signal | Wear level |
|-----------------|-----------|
| < 5 platform readers | Pristine (rare, discovered) |
| 5–20 readers | Softened (gaining readership) |
| 20–100 readers | Cracking (popular on platform) |
| 100–500 readers | WellRead (beloved community title) |
| 500+ readers | WellLoved (platform classic) |

**Condition grading (separate from wear display):**
When a seller creates a listing on Looking for a Home, they assign one of: `new | like_new | good | fair | poor`. This condition grade appears in the listing detail and is used for buyer decision-making. It is not the same as the spine wear level.

**Why this matters:** A buyer browsing Looking for a Home sees a spine with WellLoved wear and understands "this is a much-loved book on this platform" — a social proof signal. They then open the listing and see "condition: like_new" — the seller's description of the physical copy. These are complementary signals, not conflicting ones.

**Data source:** `wh.mart_community_read_count` is refreshed by the `dbt_refresh` Oban queue after each data pipeline run. Staleness is acceptable — community wear changes slowly. Spines on Looking for a Home do not update in real-time.

**Privacy note:** Community wear aggregates are anonymous — the dbt mart does not expose which users have read a book. Only counts and averages. This is enforced at the dbt model level: Tier 3 and Tier 4 personal data never leaks to warehouse models.

---

## Consequences

**Positive:**
- Looking for a Home becomes a social discovery surface — buyers discover which books the community loves, not just what's available.
- Sellers do not expose their personal reading history through the wear display (privacy benefit).
- Community wear grows more accurate as the platform gains users — a network effect where the feature improves with scale.
- The condition grade (seller input) and wear display (community signal) serve different buyer needs — physical state vs. cultural resonance.

**Negative:**
- At low user count (< 20 users), community wear is not meaningful — most spines will show Pristine regardless of how beloved the book is. This is a cold-start problem.
- `mart_community_read_count` must be kept reasonably fresh for Looking for a Home to be useful. A stale mart (days without a dbt run) means community wear is frozen. See `docs/runbooks/oban-queue-backlog.md` for recovery if dbt refresh stalls.
- The wear state is an approximation — the thresholds (5, 20, 100, 500 readers) are arbitrary and may need tuning as the platform scales. They are configurable in the dbt model, not hardcoded in Elm.

**Not a constraint:**
- Personal wear state (from the owner's reading history) is available on other bookshelves. Looking for a Home intentionally diverges from the personal history model. This is a feature, not an inconsistency.
