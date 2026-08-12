# US-6.1 — Subscribe to Shelf RSS Feeds

## 1. User Story

> **As a** user (or a friend of the user), **I want** each public shelf to have an Atom feed **so that** I can follow what someone is reading and discover books through their collection.

Each public shelf (Library, AntiLibrary, WishList, Reading Pile) automatically generates an Atom feed. The feed URL is accessible from the shelf page -- a small RSS icon in the shelf header. Friends subscribe using any RSS reader. Feed entries look like: "Erin moved The Secret History to Library" or "Erin added Piranesi to the Reading Pile" -- each with the book title, author, cover thumbnail, and timestamp.

---

## 2. UI Interaction Flow

### Happy Path
1. The **owner** views their own bookshelf page. The RSS control is an owner affordance: a viewer browsing another reader's shelf gets no feed control at all (`frontend/src/Page/Bookshelf.elm:777-791`).
2. If the bookshelf's visibility is exactly `"platform"`, an RSS button renders in the shelf header via `Components.RSSLink` (`frontend/src/Components/RSSLink.elm:33`).
3. User clicks the RSS button (`ToggleUrl`).
4. A popover displays the feed URL and the text "Subscribe in your RSS reader:", in a readonly input.
5. User copies the URL and adds it to their RSS reader.
6. The reader fetches the feed and receives Atom 1.0 XML.

**The canonical URL is the handle form.** `GET /api/feeds/u/:handle/:bookshelf_name` (`apps/core/lib/core_web/router.ex:126`) is declared first so `u` is not swallowed as a `:user_id`, and it is the only form a client can construct: profiles are addressed by handle everywhere (`/u/:handle`, `GET /api/u/:handle`), while this controller was originally keyed only by UUID — so a page showing someone's bookshelves had their handle and not their UUID and could not build a feed URL at all. The chain was broken at the *contract*, one layer below any missing call. It is also the better URL to hand a person: `/api/feeds/u/erin/library` is legible and checkable where a UUID is neither. `GET /api/feeds/:user_id/:bookshelf_name` (`router.ex:128`) is retained for links already sitting in someone's reader.

⚠️ **Residue: `RSSLink` still emits the UUID form.** `feedUrl = "/api/feeds/" ++ config.userId ++ "/" ++ config.bookshelfName` (`RSSLink.elm:38-39`). The URL works — it is the owner's own id and the route still resolves — but it is the non-canonical, unreadable one, and it is the form the handle route was added to replace.

⚠️ **Residue: the component's gate is narrower than the endpoint's.** `RSSLink` renders only when `visibility /= "platform"` is false — an exact-equality test. The endpoint's eligibility rule is `Visibility.at_least?(visibility, "platform")` (`Stacks.Feeds.feed_eligible?/1`, `apps/core/lib/stacks/feeds.ex:140`), which admits `public` as well. So a bookshelf on the **most** shared rung has a working feed that its owner is never offered a link to. (This is the same shape as the bug `at_least?/2` was introduced to fix — an equality test against one rung of a ladder — surviving on the client side.)

### Sad Paths
- **Bookshelf below the `platform` rung**: `FeedController` returns 403 — `{ error: "Feed is only available for bookshelves shared with the platform" }` (`apps/core/lib/stacks_web/controllers/feed_controller.ex:78-81`).
- **Bookshelf not found**: 404 — `{ error: "Bookshelf not found" }`.
- **Handle not found** (handle form only): 404 — `{ error: "Reader not found" }` (`feed_controller.ex:41-44`).
- **`platform` bookshelf fetched anonymously**: **404, not 403** — `{ error: "Bookshelf not found" }`. `platform` means "any authenticated platform user, **not** visible to logged-out" on the Audience ladder, so `authorize_viewer/2` returns `:not_found` rather than a 403-ish error (`feeds.ex:169-179`). Telling an anonymous client "this exists but you may not have it" would leak the shelf's existence, and `GET /api/u/:handle` already 404s the same case. A `public` bookshelf's feed is served without a viewer.
- **No placements**: feed generates with empty entries (valid Atom XML with no `<entry>` elements).
- **304 Not Modified**: if the client sends `If-None-Match` matching the current ETag, returns 304 with an empty body.
- **Cache write fails on the read path**: the fresh render is served anyway; the failure is logged and swallowed, because the cache is an optimisation (`feeds.ex:196-211`).

### Elm State Machine
- **Component module**: `Components.RSSLink`
- **Model fields involved**: `showUrl : Bool`
- **Msg flow**: `ToggleUrl` -> toggles `showUrl`
- **OutMsg pattern**: N/A

---

## 3. API Calls

Two routes, one action. Both live in the same scope (`apps/core/lib/core_web/router.ex:121-129`).

### `GET /api/feeds/u/:handle/:bookshelf_name` — canonical
- **Auth**: **Optional** (`:optional_auth`), not none. Eligibility is not uniform: a `public` bookshelf is served to anyone, a `platform` one only to a signed-in reader — serving `platform` anonymously would contradict the Audience ladder's own definition (owner decision 2026-07-29).
- **Pipeline**: `:api` -> `:optional_auth` -> `:rate_limit_public`
- **Controller**: `StacksWeb.FeedController.show/2`, handle clause (`apps/core/lib/stacks_web/controllers/feed_controller.ex:29`). Resolves the handle via `Accounts.get_user_by_handle/1` and delegates to the `user_id` clause — so the two routes cannot drift in behaviour.
- **Request headers**: optional `If-None-Match` for ETag caching
- **Response (success)**: Atom 1.0 XML — HTTP 200, with `Content-Type: application/atom+xml`, `ETag: "md5hex"`, `Cache-Control: public, max-age=300`
- **Response (304)**: empty body when `If-None-Match` matches the ETag
- **Response (error)**:
  - `{ error: "Reader not found" }` — HTTP 404 (unknown handle)
  - `{ error: "Bookshelf not found" }` — HTTP 404 (unknown bookshelf, **or** a `platform` bookshelf requested without a viewer)
  - `{ error: "Feed is only available for bookshelves shared with the platform" }` — HTTP 403 (bookshelf below the `platform` rung)

### `GET /api/feeds/:user_id/:bookshelf_name` — retained
Identical behaviour minus the handle lookup (`feed_controller.ex:51`). Kept for links already in a reader; it is what `Components.RSSLink` currently emits (see §2).

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `AuthPipeline` in optional mode -> `RateLimiter(bucket: :public)`
- **Two separate questions, two separate predicates** — this is the design worth keeping straight:
  - **Is this bookshelf feed-eligible at all?** `Feeds.feed_eligible?/1` = `Visibility.at_least?(visibility, "platform")` (`apps/core/lib/stacks/feeds.ex:140`). Checked by `resolve_shared_bookshelf/2` (`:181-191`); failure is `{:error, :not_public}` → 403.
  - **Must the requester be signed in?** `Feeds.feed_requires_auth?/1` = `not Visibility.at_least?(visibility, "public")` (`feeds.ex:156`). Checked by `authorize_viewer/2` (`:173-179`) against `Guardian.Plug.current_resource(conn)`, which `:optional_auth` populates or leaves nil; failure is `{:error, :not_found}` → 404.
- **⚠️ Both were once `visibility == "platform"` equality tests**, which refused a feed to a bookshelf on the **most** shared tier (`public`) while serving one for the *less* shared `platform` — exposure and function running in opposite directions. The `:not_public` atom is what hid it: it reads as correct at every call site, and both rejection tests only ever covered `owner` and `group`, so the literally-public case was never exercised (`apps/core/lib/stacks/visibility.ex:511-515`). `at_least?/2` treats an unknown visibility as most-private, so a typo now fails closed.
- **The predicates are functions, not duplicated literals.** `Stacks.ProtoJSON` also needs to know feed eligibility (to decide whether to advertise a feed), and it used to carry its own hardcoded `== "platform"` with a comment promising it "mirrors `Feeds` exactly" — an invariant maintained by duplication and a comment, which is to say not maintained. Calling one function makes the mirror structural (`feeds.ex:131-137`).
- **Age gate**: N/A — the feed contains metadata only, not full book content
- **Ownership checks**: none on the read path. Ownership matters only on the *client*: the RSS control renders for the owner and not for a visitor (`frontend/src/Page/Bookshelf.elm:777-780`).

---

## 5. Database Interactions

### Read: User record (handle route only)
- **Table(s)**: `op.users`
- **Query**: `Accounts.get_user_by_handle(handle)` — resolves the handle to a user id before the shared path runs
- **Schema module**: `Stacks.Accounts.User`

### Read: Bookshelf record
- **Table(s)**: `op.bookshelves`
- **Query**: `Shelving.get_bookshelf(user_id, bookshelf_name)` via `Feeds.resolve_shared_bookshelf/2` (`apps/core/lib/stacks/feeds.ex:181-191`) — finds the bookshelf, then applies `feed_eligible?/1`
- **Schema module**: `Stacks.Shelving.Bookshelf`

### Read: Cached feed
- **Table(s)**: `op.feed_cache` (one row per bookshelf, unique on `bookshelf_id`)
- **Query**: `Feeds.get_cached/1` — `Repo.get_by(FeedCacheEntry, bookshelf_id: ...)`, returning `{:ok, xml, etag}` or `:miss` (`feeds.ex:95-100`)

### Write: Fill the feed cache
- **Table(s)**: `op.feed_cache`
- **Operation**: UPSERT on the unique `bookshelf_id` index, replacing `atom_xml`, `etag`, and `updated_at` only
- **Constraint handling**: the changeset declares the `bookshelf_id` foreign key, so a bookshelf deleted between resolve and write returns `{:error, changeset}` rather than raising `Ecto.ConstraintError`
- **Read path vs job path differ deliberately**: on a read-path miss the write failure is logged and swallowed (the cache is an optimisation and the fresh render is served regardless, `feeds.ex:196-211`); in `regenerate/2` filling the cache *is* the job, so a failed write surfaces as `{:error, {:cache_write_failed, changeset}}` for the worker to retry (`feeds.ex:78-87`)

### Read: Bookshelf placements with books
- **Table(s)**: `op.bookshelf_placements` JOIN `op.books` JOIN `op.authors` JOIN `op.book_editions`
- **Query**: `Shelving.get_bookshelf_books(user_id, bookshelf_name)` — returns placements with preloaded book, author, and editions
- **Schema module**: `Stacks.Shelving.Placement`

---

## 6. Event Flow & Lifecycle

### Events Emitted
N/A — feed generation does not emit events.

### Event Handlers Triggered (upstream)
- **Handler**: `Stacks.Feeds.Handlers.PlacementHandler`
- **Listens for**: `placement.created`, `placement.moved`, `placement.removed`, `placement.restored` (`apps/core/lib/stacks/feeds/handlers/placement_handler.ex:20`)
- **Action**: Enqueues `RegenerateFeedJob` for the affected bookshelf(s) (`placement_handler.ex:22-45`)
  - `placement.created` / `placement.restored`: the payload names the bookshelf (`:66-68`, `:80-82`)
  - `placement.moved`: **two** jobs — `to_bookshelf` and `from_bookshelf`, deduplicated (`:30-32`)
  - `placement.removed`: `extract_bookshelf_name/2` returns `nil` (`:76`)
- **Downstream effects**: Atom XML regenerated and upserted into `op.feed_cache`
- **Enqueue failures** are logged, not raised (`:59-63`) — a feed lagging behind is not worth failing the placement over.

⚠️ **Residue: a removal regenerates nothing.** `extract_bookshelf_name("placement.removed", _)` returns `nil`, and `nil` is then dropped by `Enum.reject(&is_nil/1)` (`placement_handler.ex:35`), leaving an empty list — so `Enum.each` enqueues no job at all. The code comment at `:74-76` reasons that a removal "carries no bookshelf name and needs none: whichever feed the book was in loses it, and `lookup_user_id/1` plus a full regeneration covers that", but there is no regeneration to cover it: the cached `op.feed_cache` row is never rewritten. A removed book therefore stays in the published feed until some *other* placement event on the same bookshelf triggers a regeneration. The `nil` reads as "no specific bookshelf, regenerate broadly" and behaves as "skip".

---

## 7. Background Jobs (Oban)

### RegenerateFeedJob
- **Worker**: `Stacks.Workers.RegenerateFeedJob` (`apps/core/lib/stacks/workers/regenerate_feed_job.ex`)
- **Queue**: `:default`, **max attempts 3** (`:27`)
- **Args**: `%{"user_id" => uuid, "bookshelf_name" => name}`
- **What it does**: calls `Feeds.regenerate/2` — renders the Atom XML and upserts the `op.feed_cache` row. Idempotent: two runs over unchanged data leave a single row with the same etag, because the etag is a pure function of the XML.
- **On a non-eligible bookshelf**: a no-op — logs at debug, writes no row, returns `:ok`.
- **On cache-write failure**: `{:error, {:cache_write_failed, changeset}}`, so Oban retries. Unlike the read path, filling the cache *is* this job's purpose, so a dropped write must not be silent.
- **Deliberately NOT `unique:`** (`:15-26`). Placing N books enqueues N identical regenerations, which is wasteful but harmless — the job recomputes the whole feed and upserts one row, so the end state is correct either way. Deduping is a trap worth knowing: Oban warns that unique `states` omitting `:executing` may break uniqueness, and adding `:executing` introduces a **lost update** here — a regeneration already running may have read the placements before the newest one committed, so collapsing the newest event into it drops that book from the feed until something else triggers a regeneration. Any dedup must therefore exclude `:executing` (and accept the warning), or debounce rather than deduplicate.
- **If the job never runs**: the read path fills the cache on a miss, so a first request still gets a correct feed. What the job protects is *freshness* of an already-cached feed — which is why the removal gap in §6 matters.

---

## 8. External Service Calls

N/A — feed generation is entirely local. No external APIs called.

---

## 9. Storage (R2 / Local)

N/A for R2 — but feed content **is** persisted, in Postgres rather than object storage: `op.feed_cache`, one row per bookshelf (`atom_xml`, `etag`, `updated_at`), read by `Feeds.get_cached/1` and written by both the read-path miss-fill and `RegenerateFeedJob`. Schema module `Stacks.Feeds.FeedCacheEntry` (`apps/core/lib/stacks/gen/feeds/feed_cache_entry.ex` — proto-generated by `mix proto.sync`; do not hand-edit).

---

## 10. Cache Interactions

Two layers, and they are independent.

### Server-side: `op.feed_cache` (persisted)
- **Operation**: `Feeds.get_cached/1` on every request; hit serves the stored XML, miss renders and fills (`render_and_serve/1`)
- **Key**: `bookshelf_id` (unique index, one row per bookshelf)
- **TTL**: none. The row lives until it is overwritten — there is no expiry, so correctness depends entirely on the invalidation path.
- **Invalidation trigger**: `RegenerateFeedJob`, enqueued by `PlacementHandler` on placement events. ⚠️ Not on `placement.removed` — see §6.
- **Survives restarts**, unlike an ETS cache, which is why it is a table.

### Client-side: HTTP ETag
- **Operation**: the etag is a pure function of the XML (`Feeds` computes it alongside the render), returned as `ETag: "…"`; a matching `If-None-Match` gets a 304 with an empty body (`feed_controller.ex:59-71`)
- **TTL**: `Cache-Control: public, max-age=300` (5 minutes). This is the floor on feed staleness even when the server cache *is* fresh — a well-behaved reader will not re-ask sooner.

---

## 11. dbt Model Dependencies

N/A — feed generation reads directly from operational tables, not dbt models.

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: N/A — the RSS component appears on bookshelf pages, not as a standalone route
- **URL**: N/A. The canonical feed URL is `/api/feeds/u/:handle/:bookshelf_name`; the URL this component *builds* is the retained `/api/feeds/:user_id/:bookshelf_name` form (see the residue note in §2)
- **Public or authenticated**: the component appears on the authenticated bookshelf page, and only for the owner — `Page.Bookshelf` omits it entirely when `cfg.readOnly` (`frontend/src/Page/Bookshelf.elm:777-791`)
- **Mounted at**: `Page.Bookshelf` — `import` `:25`, model field `organiser`-adjacent `rssLink : RSSLink.Model` `:163`, `Msg` `:246`, `init` `:300`, `update` `:411-412`, `view` `:783-790`

### Init
- **`initPage` branch**: N/A — `Components.RSSLink.init` returns `{ showUrl = False }`
- **API calls on init**: None
- **Initial model state**: `{ showUrl = False }`

### Update cycle
- **Msg**: `ToggleUrl` -> toggles `showUrl` between True and False
- **Model change**: `{ model | showUrl = not model.showUrl }`
- **Cmd**: None
- **OutMsg**: N/A

### View
- **Key elements** (`frontend/src/Components/RSSLink.elm:31-59`):
  - Renders only when `config.visibility == "platform"` — returns empty `text ""` otherwise. This exact-equality test is narrower than the endpoint's `at_least?` rule, so a `public` bookshelf's working feed is never offered (§2).
  - RSS button with an "RSS" text label — a text span, not an icon, despite the class name `rss-link__icon`.
  - When `showUrl` is True: a popover with help text "Subscribe in your RSS reader:" and a readonly input containing the feed URL, built as `/api/feeds/{userId}/{bookshelfName}` (`:38-39`).
  - When `showUrl` is False: just the button.
- **No copy affordance.** The URL is a readonly input the reader must select and copy by hand; there is no copy button and no confirmation that anything was copied.
- **ARIA attributes**: none. The button has no `aria-expanded`, and the popover is not announced — so for a screen-reader user, pressing the button reports nothing.
- **CSS classes**: `rss-link`, `rss-link__button`, `rss-link__icon`, `rss-link__popover`, `rss-link__help`, `rss-link__url`

### Atom Feed XML Structure
```xml
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>{displayName}'s {Bookshelf Name}</title>
  <id>urn:stacks:feed:{bookshelf_id}</id>
  <updated>{latest_placement_date}</updated>
  <author><name>{displayName}</name></author>
  <entry>
    <title>{book_title}</title>
    <id>urn:stacks:placement:{placement_id}</id>
    <updated>{placed_at}</updated>
    <summary>{title} by {author} {added|moved} to {Bookshelf Name}</summary>
    <author><name>{author_name}</name></author>
    <link rel="enclosure" href="{cover_url}" />
    <link rel="related" href="https://openlibrary.org/isbn/{isbn}" />
  </entry>
</feed>
```

- **The verb is real**, not always "added": `verb = if Map.has_key?(moved_ids, placement.book_id), do: "moved", else: "added"` (`apps/core/lib/stacks/feeds.ex:310-314`), so the story's "Erin moved The Secret History to Library" is what a reader actually gets.
- **Missing author** renders as "Unknown Author" rather than being omitted (`feeds.ex:300-301`).
- **Missing `placed_at`** falls back to `now` — an entry always carries an `<updated>`.
- **Cover thumbnail** is an Atom enclosure taken from the primary edition (`cover_link/1`, `feeds.ex:329-334`) — it is what makes the feed browsable in a reader rather than a list of sentences.
- All interpolated text passes through `escape_xml/1`.

---

## 13. Operational Metrics

- **Oban job counts for `RegenerateFeedJob`**: enqueued, completed, failed, retried. Note the enqueue count is **not** one per placement event — `placement.moved` enqueues two, and `placement.removed` enqueues zero (§6), so a divergence between placement-event volume and job volume is expected and its size is the measurement of that gap.
- **Feed request counts**, split by route (`/feeds/u/:handle/…` vs `/feeds/:user_id/…`) and status: 200, 304, 403, 404. **The route split is the metric that would prove the `RSSLink` residue matters**: if essentially all traffic is on the `:user_id` form, no client is producing handle URLs.
- **Server-cache hit rate**: `Feeds.get_cached/1` hits vs misses. A high miss rate on a stable bookshelf means regenerations are not landing.
- **ETag cache hit rate**: ratio of 304s to total feed requests — higher is better, and indicates readers caching effectively.
- **403 vs 404 breakdown**: a 403 is "this bookshelf is not shared widely enough for a feed"; a 404 may be a genuinely missing bookshelf **or** a `platform` bookshelf requested anonymously, which is deliberately indistinguishable from outside. So the 404 count is not a clean "broken link" signal, and treating it as one would misread the ladder's intentional ambiguity.
- **Event handler execution times**: `PlacementHandler` latency from placement event to enqueue. Enqueue failures are logged and swallowed (`placement_handler.ex:59-63`), so a warning-log rate is the only signal that a regeneration was dropped.
- **Rate limiter activity**: `:rate_limit_public` bucket for the feed routes — monitors for aggressive reader polling.

None of these are emitted as bespoke telemetry; the HTTP figures come from Phoenix endpoint metrics and the job figures from Oban's.

---

## 14. Performance & Usability Metrics

- **RSS feed generation time**: elapsed time to generate Atom XML for a bookshelf -- depends on placement count. Target: <100ms for bookshelves with <500 placements.
- **Feed XML size**: bytes per generated feed -- affects RSS reader fetch times and network egress
- **Feed subscriber count**: unique `User-Agent` strings or IP addresses hitting feed URLs -- proxy for how many RSS readers are subscribed
- **Feed freshness**: time between a placement event and the feed reflecting it. For an add or a move: `RegenerateFeedJob` latency plus the `max-age=300` header, so ~5 minutes. For a **removal**: unbounded — no job is enqueued and `op.feed_cache` has no TTL, so the removed book stays in the published feed until an unrelated placement on the same bookshelf triggers a regeneration (§6). This is the story's worst-case freshness number and it is not five minutes.
- **Feed entry quality**: percentage of entries with complete metadata (book title, author name, ISBN link) vs entries with missing fields

---

## 15. Cost Tracking

- **Fly.io compute**: core app machine time for `RegenerateFeedJob` (event-triggered) and `FeedController.show/2` (on-demand). Feed generation is CPU-light (string concatenation + MD5 hash). Fly.io shared-cpu-1x: ~$1.94/month base.
- **Neon compute**: feed generation queries `op.bookshelves`, `op.bookshelf_placements`, `op.books`, `op.authors`, `op.book_editions` with preloads. One multi-join query per feed request (or per regeneration job). Neon free tier: 191.9 compute hours/month; paid: $0.16/compute-hour.
- **Network egress**: Atom XML served to RSS readers. Typical feed size: 5-50KB. With `Cache-Control: public, max-age=300`, well-behaved readers poll at most every 5 minutes. 100 subscribers polling every 5 minutes: ~1.4GB/month. Fly.io free tier: 100GB/month; $0.02/GB after.
- **No external API costs**: feed generation is entirely local -- no Brave, Together AI, or scraper calls.
