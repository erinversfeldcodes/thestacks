# US-6.2.1 — POSSE: Syndicate a Post to Substack

## 1. User Story

> **As a** writer on The Stacks, **I want** my post to live here as the canonical original and be syndicated out to Substack **so that** I reach the readers who are already there without handing my writing's permanent address to someone else's platform.

**POSSE** — Publish On your own Site, Syndicate Elsewhere. The post on The Stacks is the original and the permanent address. The Substack copy is a copy, and says so: it carries `rel="canonical"` back here, and it opens with a line pointing home.

**Be honest about the mechanism.** Substack has **no official write or publish API**. There is no OAuth flow to build and no "Publish to Substack" button that could truthfully exist. What is actually available is three things, and the story ships the first two:

1. **A public blog Atom feed** — `GET /api/feeds/u/:handle/blog` — which Substack's own RSS import consumes. Set it up once in Substack and new public posts arrive as drafts.
2. **A canonical-tagged export** — the post rendered as paste-ready HTML or Markdown with the canonical link and an "Originally published on The Stacks" line already in it, for the reader who prefers to paste and polish.
3. **Email-to-Substack** — deferred; Substack's per-publication ingest address is not reliably available and building on it would be building on sand.

Saying "no write API, so here is what honestly works" is the point. A fake integration would be worse than none.

**How they accomplish it:**
1. The writer publishes a post as normal (US-12.1.1), with visibility **public**.
2. On the published post — and in the editor's post-publish panel — a **Syndicate** section appears.
3. First time only: they copy the blog feed URL and paste it into Substack's *Settings → Import → RSS*. One-time setup, then every future public post arrives in Substack by itself.
4. For any single post they can instead click **Copy for Substack**, paste into Substack's editor, and publish there.
5. Once the Substack copy is live, they paste its URL back into the "Also published at" field. The post on The Stacks then shows the backlink — the second half of POSSE.

**What they see on the page:**
- Below the post body, set off by a hairline rule and typeset small, a section headed **Syndication** with a subdued brass tint (`post__syndication`).
- The canonical line first, because it is the fact everything else depends on:
  > **Canonical address** — `https://thestacks.app/blog/8f2c…` — with a copy button. Beneath it: "This is where this piece lives. Anywhere else it appears should point back here."
- Then the two affordances, side by side:
  - **Copy for Substack** — a small split control offering *HTML* or *Markdown*. On click the button label becomes "Copied — paste it into Substack" for three seconds. The copied text opens with `*Originally published on [The Stacks](canonical).*` and ends with the same note; the HTML variant carries `<link rel="canonical">`.
  - **Your blog feed** — the feed URL with a copy button and one sentence: "Paste this into Substack once, under Settings → Import → RSS. Every public post you write from then on arrives there as a draft."
- Then **Also published at** — an input for the Substack URL, or, once set, the URL as a link with a small "edit" affordance. When set, a line appears near the top of the post itself: "Also at *Substack*."
- Then the control, stated plainly rather than buried in a settings page:
  > ☑ **Include this post in my public feed** — "Unticking this keeps the post public on The Stacks but takes it out of the feed Substack reads. Already-syndicated copies stay where they are."
- **When the post is not public**, the whole section is replaced by one honest sentence: "This post is visible to *platform readers* only, so there is nothing to syndicate. Syndication sends a piece to a place with no idea who your readers are — only public posts can go." Followed by a link to the post's visibility control. The affordances are **absent**, not disabled-and-greyed: a greyed button invites a click that will never work.
- A closing caption, because the alternative is a support request later:
  > "Syndication is a copy, not a mirror. If you edit or delete this post here, the Substack copy stays as it was — you'd need to change it there too."

**Acceptance criteria:**
- The blog feed contains **only** posts whose visibility is `public` **and** whose `syndicated` flag is set. A `platform`, `group`, or `owner` post can reach it by no code path.
- The blog feed endpoint takes no viewer: it is anonymous-only, so there is no authenticated branch through which a non-public post could be served.
- Every syndication artefact — feed entry, HTML export, Markdown export — carries the canonical URL back to The Stacks.
- The canonical URL for a post is stable for the life of the post and never changes.
- Unticking "include in my public feed" removes the post from the feed on the next fetch and does not change its visibility.
- A recorded syndication survives in `op.post_syndications` with the canonical URL as it was at the time.
- Nothing in this story sends a request to Substack. The platform never holds a Substack credential.

---

## 2. UI Interaction Flow

### Happy Path (one-time feed setup)
1. Writer views their own published public post at `/blog/:id`.
2. `Page.Blog.Post` renders `viewSyndication` because `post.visibility == "public"` and `post.isOwn`.
3. Writer clicks the feed URL's copy button → `ClickedCopyFeedUrl` → `Ports.copyToClipboard url` → `copyState = Copied FeedUrl`.
4. They paste it into Substack. Nothing further happens on The Stacks — that is the shape of an honest integration with a platform that has no API.
5. Substack fetches `GET /api/feeds/u/erin/blog`, receives Atom 1.0, and creates drafts.

### Happy Path (per-post export)
1. Writer clicks **Copy for Substack → Markdown** → `ClickedCopyExport Markdown`.
2. `Api.fetchSyndicationExport postId Markdown` → `GET /api/blog/posts/:id/syndication?format=markdown`.
3. `GotExport (Ok body)` → `Ports.copyToClipboard body`, `copyState = Copied (Export Markdown)`, and a `POST /api/blog/posts/:id/syndications` records `method: "export"`.
4. Writer pastes into Substack, publishes, copies the resulting URL.
5. Writer pastes it into **Also published at** → `SyndicatedUrlSubmitted` → `PUT /api/blog/posts/:id/syndications/:sid`.
6. The post now shows "Also at *Substack*."

### Sad Paths
- **Post is not public**: `viewSyndication` renders the explanatory sentence and the visibility link. No API call is made.
- **Post is public but `syndicated` is false**: the feed section shows "This post is out of your feed" with the tickbox unticked; the export affordance still works, because an export is a deliberate one-off act by the author and not an automated republication.
- **Clipboard unavailable** (no permission, or an older browser): the export text is revealed in a readonly `textarea`, pre-selected, with "Select all and copy". A copy button that silently fails is worse than a textarea.
- **Export fetch fails**: `GotExport (Err _)` → the button shows "Couldn't fetch that — try again", and the recorded-syndication call is not made. A syndication row for an export the writer never received would be a lie in the record.
- **Invalid "Also published at" URL**: 422 `{ "error": "invalid_url" }`. Field message: "That doesn't look like a web address." Only `http`/`https` are accepted, and the value is rendered with `rel="nofollow noopener"` — it is a user-supplied outbound link.
- **Feed requested for an unknown handle**: 404 `{ "error": "Reader not found" }`.
- **Feed requested for a handle with no public posts**: HTTP 200 with a valid, empty Atom document. An empty feed is the correct answer and Substack handles it; a 404 would make Substack drop the subscription.
- **Feed requested with an auth token**: the token is ignored. There is no `:optional_auth` on this route (see §4).

### Elm State Machine
- **Page modules**: `Page.Blog.Post` (the published-post view) and `Page.Blog.Editor` (post-publish panel), both delegating to a shared `Components.Syndication`
- **Model fields involved**: `syndication : SyndicationModel` — `{ copyState, exportState, syndicatedUrlInput, syndications, includeInFeed }`
- **Msg flow**: `ClickedCopyCanonical` / `ClickedCopyFeedUrl` / `ClickedCopyExport Format → GotExport → SyndicatedUrlChanged → SyndicatedUrlSubmitted → GotSyndicationSaved` / `ToggledIncludeInFeed → GotPostUpdated`
- **RemoteData states**: `exportState : RemoteData Http.Error String`
- **OutMsg pattern**: `SyndicationChanged Post` propagates the updated post up so the parent page's copy of `post.syndicated` does not go stale under the tickbox.

---

## 3. API Calls

### `GET /api/feeds/u/:handle/blog`
- **Auth**: **None, and deliberately no `:optional_auth`**
- **Pipeline**: `:api`, `:rate_limit_public`
- **Controller**: `StacksWeb.BlogFeedController.show/2`
- **Request headers**: optional `If-None-Match`
- **Response (success)**: Atom 1.0 XML — HTTP 200, `Content-Type: application/atom+xml`, `ETag: "<md5hex>"`, `Cache-Control: public, max-age=300`
- **Response (304)**: empty body when `If-None-Match` matches
- **Response (error)**: `{ error: "Reader not found" }` 404
- ⚠️ **Route ordering.** This must be declared **before** `get "/feeds/u/:handle/:bookshelf_name"` in the router, or `:bookshelf_name` swallows `"blog"` and the request is answered as a lookup for a bookshelf named "blog" — a 404 that looks like a missing reader. Add a router test that asserts `/api/feeds/u/erin/blog` reaches `BlogFeedController`.

### `GET /api/blog/posts/:id/syndication`
- **Auth**: Required, author of the post
- **Pipeline**: `:api`, `:authenticated`
- **Controller**: `StacksWeb.BlogController.syndication/2`
- **Query params**: `format` — `html` (default) or `markdown`
- **Response (success)**: `{ format: "markdown", canonical_url: "...", body: "..." }` — HTTP 200
- **Response (error)**: `{ error: "not_found" }` 404 (another author's post, or an unpublished one) · `{ error: "not_public" }` 422
- **Author-only, not public**: the export is an authoring tool. The public artefact is the feed.

### `POST /api/blog/posts/:id/syndications`
- **Auth**: Required, author
- **Request body**: `{ "target": "substack", "method": "export" | "rss" }`
- **Response**: `{ syndication: { id, target, method, canonical_url, syndicated_url, created_at } }` — HTTP 201

### `PUT /api/blog/posts/:id/syndications/:sid`
- **Request body**: `{ "syndicated_url": "https://name.substack.com/p/slug" }`
- **Response**: `{ syndication: { ... } }` — HTTP 200 · `{ error: "invalid_url" }` 422

### `PUT /api/blog/posts/:id` (extended)
- The existing update endpoint gains `syndicated` (boolean) in its accepted params. The tickbox is a post property, not a new endpoint.

### `PUT /api/settings/profile` (extended)
- Gains `syndication_default` (boolean) so the writer's preference applies to future posts without touching each one.

---

## 4. Auth & Middleware Guards

- **Plugs fired (feed)**: `SecurityHeaders` → `RateLimiter(bucket: :public)`. 200/60s per trusted client IP.
- **⛔ The absence of `:optional_auth` on the blog feed is a security control, not an omission.** US-6.1's shelf feed is `:optional_auth` because a `platform` bookshelf's feed is legitimately visible to a signed-in platform reader. A **syndication** feed has the opposite requirement: its consumer is an anonymous third-party fetcher with no idea who anyone is, and anything it can read may end up republished. Removing the viewer from the picture entirely means there is no branch in which a `platform` post can be served. Guard it with a test that fetches the feed **with** a valid owner token and asserts the platform-visible post is still absent.
- **Visibility checks**: `Stacks.Visibility.at_least?(post.visibility, "public")` — the top of the Audience ladder (`owner < group < platform < public`), and here the minimum *is* the top. Combined with `post.syndicated` and a non-nil `published_at`.
- **Age gate**: N/A — posts are not age-gated. If post-level age-gating is ever added, this feed must exclude gated posts, since a syndicated copy escapes every gate we own.
- **Ownership checks (export, syndication records)**: `BlogController` scopes by `current_resource.id`; a non-author gets 404, not 403.
- **Outbound link hygiene**: `syndicated_url` is user-supplied. Validate the scheme is `http`/`https`, reject anything else, and render with `rel="nofollow noopener"`.

---

## 5. Database Interactions

### Write: Additive fields on `op.blog_posts`
- Add `syndicated` (boolean, NOT NULL, default `true`) to `proto/stacks/common/v1/blog.proto`, then `mix proto.sync`. `git add` the generated migration immediately.
- **Why the default is `true` and not `false`**: an opt-in default leaves the feed empty, which makes the feature dead on arrival and teaches nobody it exists. Publishing a post *publicly* is already the consenting act; syndication carries it to readers, which is what publishing publicly is for. The per-post tickbox and the account-level default are the control, and both are visible at the moment of publishing rather than buried.

### Write: Additive field on `op.users`
- Add `syndication_default` (boolean, NOT NULL, default `true`) to `proto/stacks/common/v1/user.proto`. Applied by `Blog.create_post/2` when it sets a new post's `syndicated`.
- ⚠️ A new `op.users` column means the **`op.users` schema-sweep guard** in `test/stacks/gdpr_test.exs` will fail until the column is classified. It is a preference, not personal data, and belongs in the exported set alongside the `notify_*` flags — add it to `GDPR.Export`'s `user:` map, not to the exclusion list.

### Write: New table `op.post_syndications`
- **Proto source**: add `PostSyndication` to `proto/stacks/common/v1/blog.proto`, register in `proto/persisted.exs`, `mix proto.sync`.
- **Columns**: `id` · `post_id` (uuid FK `op.blog_posts`, **ON DELETE CASCADE**) · `target` (text, NOT NULL, default `"substack"`) · `method` (text, NOT NULL — `rss` | `export`) · `canonical_url` (text, NOT NULL) · `syndicated_url` (text, nullable) · `created_at`
- **Indexes**: `post_syndications_post_id_index`.
- **Changeset validations**: `target` inclusion, `method` inclusion, `syndicated_url` scheme in `~w(http https)` when present.
- **Why `canonical_url` is stored rather than derived**: it is the address that was actually published elsewhere. If the platform's host ever changes, a derived value would silently rewrite history and the recorded backlink would no longer match what the Substack copy says.

### Read: Feed query
- **Table(s)**: `op.blog_posts` JOIN `op.users`
- **Query**: `where post.user_id == ^user_id and post.visibility == "public" and post.syndicated and not is_nil(post.published_at)`, `order_by [desc: :published_at]`, `limit 20`.
- **Indexes**: add `blog_posts_user_public_published_idx` on `(user_id, published_at DESC) WHERE visibility = 'public' AND syndicated`. A partial index, because the feed only ever asks for that slice.
- **Deliberately not joined**: `op.post_book_associations`. The books a post is about are inferred by an LLM (US-12.1.2) and may be unconfirmed; shipping unconfirmed inferences into a third-party republication is not a risk worth a richer feed entry.

### GDPR: erasure + export reachability
- **Erasure**: `op.blog_posts.user_id` is `ON DELETE CASCADE` (`20260319000004_create_blog_tables.exs`), and `post_syndications.post_id` cascades from the post. So erasure reaches the new table transitively through the existing `repo.delete(user)`. **Add a test that asserts it** — a two-hop cascade is exactly the kind of guarantee that is true today and silently untrue after someone weakens an FK.
- **Export**: add a `blog_syndications` key — `{ post_id, target, method, canonical_url, syndicated_url, created_at }`.
  ⚠️ **Pre-existing gap, flagged not fixed here**: `GDPR.Export.export_user_data/2` currently exports **no blog data at all** — not posts, not comments, not associations — while `op.blog_posts.body` is the reader's own writing and squarely within the right to portability. Exporting a post's *syndication records* while omitting the post itself would be an odd export. Raise this as its own issue against US-8.1 rather than widening this story; note it in the story's DoD so it is not lost.
- **`event_log`**: `post.syndicated`'s payload carries no title and no body (§6).
- **Third-party disclosure**: syndication moves the writer's words to a service The Stacks does not control and cannot erase from. The UI says so in the closing caption, and `/faq` (US-15.4.1) should carry the same answer. This is a disclosure obligation, not a consent gate — the writer performs the copy themselves in both mechanisms.

---

## 6. Event Flow & Lifecycle

### Events Emitted

#### `post.syndicated`
- **Aggregate**: `blog_post` / post_id
- **Payload**: `%{target: "substack", method: "export" | "rss"}`
- **Emitted by**: `Stacks.Blog.record_syndication/2`
- **Emission method**: `Events.emit_safe/1`
- No title, no body, no canonical URL, no Substack URL. A URL containing a slug derived from a title is title data by another name.

#### `post.published` (existing)
Unchanged. The feed is generated on request, so publishing needs no new event to make a post syndicable.

### Event Handlers Triggered
- **Handler**: none new. The feed is computed per request behind an ETag; there is no cached artefact to invalidate.
- ⚠️ **If a blog-feed cache is ever added**, `op.feed_cache` is the wrong home as it stands: it is keyed on `bookshelf_id`, and `GDPR.Deletion`'s `:delete_feed_cache` step is scoped to the erased user's bookshelf ids. A blog-feed row keyed on anything else would sit outside that scope and outside the `op.users` schema guard — an erasure hole. Any such cache needs its own explicit erasure step in the same change. Recorded here so the follow-up cannot be built innocently.

---

## 7. Background Jobs (Oban)

**None.** The feed is generated per request (at most 20 posts, one indexed query, string building) behind a 5-minute `Cache-Control` and an ETag. Substack polls on its own schedule. A regeneration job would be machinery in service of nothing — the shelf feed has one because placements change constantly and a shelf can hold hundreds of books; a blog changes when someone writes.

---

## 8. External Service Calls

**None, and that is the design.** The platform makes no request to Substack, holds no Substack credential, and stores no Substack token. Substack pulls the feed; the writer pastes the export. There is nothing to rate-limit, no circuit breaker to add, no OAuth refresh to fail at 3am, and no third-party outage that can break publishing on The Stacks.

The one inbound external actor is Substack's feed fetcher, which is an anonymous HTTP client and is treated as one — `:rate_limit_public`, ETag, `max-age=300`.

---

## 9. Storage (R2 / Local)

N/A. The feed and the export are both generated in-process.

---

## 10. Cache Interactions

- **HTTP ETag**: MD5 of the generated XML, via the existing `Feeds.compute_etag/1`. Returned as `ETag`; a matching `If-None-Match` gets 304.
- **`Cache-Control: public, max-age=300`** — five minutes, matching the shelf feed. A well-behaved importer polls at most every five minutes; a new post is visible to Substack within that window.
- **`op.feed_cache`**: **not used** (see the §6 warning).
- **`RateLimiter`**: `:public` bucket, keyed on the trusted client IP.

---

## 11. dbt Model Dependencies

- **Model**: `stg_post_syndications` — proto-generated. Columns are all non-free-text (ids, target, method, two URLs, a timestamp). ⚠️ `syndicated_url` and `canonical_url` are safe to warehouse; if a `slug` is ever derived from post titles, revisit — a slug in the warehouse is title text in the warehouse.
- **Model**: `int_syndication_reach` — new intermediate joining syndication counts to `stg_blog_posts`, answering "what share of public posts get syndicated, and by which method".
- **Trigger**: `post.syndicated` via `DbtRefreshHandler`.
- **Consumer**: the writer-facing insights page (US-12.x) and the owner's platform stats.

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variants**: none new. `Route.BlogPost String` (`/blog/:id`) and `Route.BlogEdit String` already exist; the syndication panel is a component on both.
- ⚠️ **Canonical URL and the slug question.** The canonical address is `https://<host>/blog/:id` — the post's UUID. It is ugly and it is *permanent*, and POSSE's requirement is permanence, not prettiness: once a canonical URL is published in a third-party copy it can never move. A `slug` would read better but introduces a per-user uniqueness surface, a redirect obligation for every edited title, and a second address for the same post — three ways to break a canonical link. **Deferred deliberately**, with the reasoning recorded here rather than left as an oversight. Flag it for the owner; if slugs land later, the UUID form must keep resolving forever.

### Init
- **`initPage` branch**: unchanged. `Components.Syndication.init post` derives its state from the post already in the model — no extra fetch on page load. The export is fetched only when asked for; pre-fetching a formatted copy of a post nobody is syndicating is waste.

### Model (`Components.Syndication`)
```
{ copyState : CopyState            -- Idle | Copied CopyTarget | CopyUnavailable
, exportState : RemoteData Http.Error String
, exportFormat : Format            -- Html | Markdown
, syndicatedUrlInput : String
, syndicatedUrlValidation : FieldValidation
, syndications : List Syndication
, includeInFeed : Bool
}
```

### Update cycle

| Msg | Model change | Cmd | OutMsg |
|-----|-------------|-----|--------|
| `ClickedCopyCanonical` | `copyState = Copied Canonical` | `Ports.copyToClipboard canonicalUrl` | `NoOut` |
| `ClickedCopyFeedUrl` | `copyState = Copied FeedUrl` | `Ports.copyToClipboard feedUrl` | `NoOut` |
| `ClickedCopyExport fmt` | `exportState = Loading`, `exportFormat = fmt` | `Api.fetchSyndicationExport postId fmt` | `NoOut` |
| `GotExport (Ok body)` | `exportState = Success body`, `copyState = Copied (Export fmt)` | `Ports.copyToClipboard body` then `Api.recordSyndication postId "export"` | `NoOut` |
| `GotExport (Err e)` | `exportState = Failure e` | None | `NoOut` |
| `SyndicatedUrlChanged s` | `syndicatedUrlInput = s`, revalidate | None | `NoOut` |
| `SyndicatedUrlSubmitted` | — | `Api.updateSyndication` | `NoOut` |
| `GotSyndicationSaved (Ok s)` | `syndications` updated | None | `NoOut` |
| `ToggledIncludeInFeed` | `includeInFeed` toggled | `Api.updatePost postId { syndicated = … }` | `SyndicationChanged post` |
| `CopyTimeoutElapsed` | `copyState = Idle` | None | `NoOut` |

### Ports
`Ports.copyToClipboard : String -> Cmd msg` — the one place this story needs a port, because the Clipboard API has no Elm equivalent. ⚠️ Per the project's no-ports-unless-necessary rule, this is the necessary case; the JS side must resolve or reject so `CopyUnavailable` is reachable and the textarea fallback actually appears. A port that silently swallows a rejection produces a button that appears to work and does not — the "built but not wired" shape.

### View
- **Key elements**: `viewCanonical`, `viewExportControls`, `viewFeedUrl`, `viewAlsoPublishedAt`, `viewIncludeInFeed`, and `viewNotPublic` (the replacement branch).
- **ARIA**: each copy button's confirmation is announced through an `aria-live="polite"` region rather than by mutating the button label alone, so a screen-reader user learns the copy happened. The tickbox is a real `input[type=checkbox]` with a `label`, not a styled div.
- **CSS classes**: `post__syndication`, `post__syndication-canonical`, `post__syndication-actions`, `post__syndication-feed`, `post__syndication-backlink`, `post__syndication-toggle`, `post__syndication-unavailable`, `post__also-at`. ⚠️ Every one needs a rule in `frontend/css/main.css` in the same change — re-run the Elm-class-literal set difference, confirm zero new orphans, and let `scripts/check-css.sh` gate it. `post__also-at` in particular renders near the top of the post and will look broken unstyled.
- **Test ids**: `syndication-panel`, `syndication-canonical-copy`, `syndication-feed-url`, `syndication-export-markdown`, `syndication-export-html`, `syndication-also-at-input`, `syndication-include-toggle`, `syndication-unavailable`.

### Atom feed structure
```xml
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>{displayName} — Writing on The Stacks</title>
  <id>urn:stacks:blogfeed:{user_id}</id>
  <updated>{latest_published_at}</updated>
  <author><name>{displayName}</name></author>
  <link rel="alternate" type="text/html" href="https://{host}/u/{handle}" />
  <link rel="self" type="application/atom+xml" href="https://{host}/api/feeds/u/{handle}/blog" />
  <entry>
    <title>{post_title}</title>
    <id>urn:stacks:post:{post_id}</id>
    <updated>{updated_at}</updated>
    <published>{published_at}</published>
    <!-- The canonical link. This is the load-bearing element of the whole story. -->
    <link rel="alternate" type="text/html" href="https://{host}/blog/{post_id}" />
    <content type="html">
      &lt;p&gt;&lt;em&gt;Originally published on &lt;a href="https://{host}/blog/{post_id}"&gt;The Stacks&lt;/a&gt;.&lt;/em&gt;&lt;/p&gt;
      {escaped_post_body}
    </content>
  </entry>
</feed>
```
The "Originally published on" line is inside `<content>` rather than only in `<link>` because Substack's RSS import carries the content through and may or may not preserve a canonical hint. A visible sentence in the body survives any importer.

---

## 13. Operational Metrics

- **Blog feed request counts**: `GET /api/feeds/u/:handle/blog` by status — 200, 304, 404. The 304 share is the importer-politeness figure.
- **ETag hit rate**: 304 / total. A low rate against a known importer User-Agent means the ETag is churning — likely a timestamp in the generated XML that changes on every render.
- **Export fetch counts**: `GET /api/blog/posts/:id/syndication` by format. Tells you whether writers prefer the feed or the paste, which decides where the next increment of effort goes.
- **Syndications recorded**: counter by `method` (`rss` | `export`) from `post.syndicated`.
- **Backlinks completed**: share of `op.post_syndications` rows with a non-null `syndicated_url`. This is the POSSE loop closing; a low share means the "Also published at" field is not being found.
- **Visibility-leak guard**: assert-and-alert — a scheduled check that fetches every public handle's blog feed and asserts no entry corresponds to a non-public post. Cheap, and the one failure in this story that would be genuinely bad.
- **Rate limiter**: `stacks_rate_limit_rejected_count_total{bucket="public"}` correlated with feed fetches — an aggressive importer polling every minute would show here.
- **Feed generation duration**: histogram. One indexed query and string building for at most 20 posts; target p95 < 50ms.

---

## 14. Performance & Usability Metrics

- **Feed generation time**: target p95 < 50ms for a 20-entry feed. If it drifts, the cause is the body escaping, not the query.
- **Feed document size**: bytes per feed. Full post bodies make this far larger than a shelf feed — a 20-post feed of long essays can reach several hundred KB. If egress becomes material, truncate `<content>` to an excerpt plus the canonical link and say so in the UI; do **not** truncate silently, since a syndicated excerpt where the writer expected a full post is a content decision, not an optimisation.
- **Time from publish to Substack draft**: `published_at` to the first feed fetch that includes the post. Bounded below by `max-age=300` and above by Substack's poll interval. Set the expectation in the UI ("usually within the hour") rather than promising immediacy the mechanism cannot deliver.
- **Syndication adoption**: share of writers with at least one public post who have copied the feed URL at least once.
- **Copy-button success rate**: `Copied` vs `CopyUnavailable` outcomes from the port. A meaningful `CopyUnavailable` share means the textarea fallback is load-bearing and needs to look deliberate.
- **Panel discoverability**: share of public-post views by their author that scroll the syndication panel into view. If it is low the panel is too far down the page.
- **Tickbox usage**: how often "include this post in my public feed" is unticked. Near-zero validates the `true` default; a meaningful share means writers want opt-in and the account-level default should flip.

---

## 15. Cost Tracking

- **Fly.io compute**: one indexed query plus string building per feed fetch, at most every five minutes per subscriber. Immaterial against the `~$1.94/month` shared-cpu-1x base.
- **Neon compute**: one partial-index-served query per uncached feed fetch and one small insert per recorded syndication. Negligible.
- **Network egress**: the real cost, and larger than the shelf feed's because entries carry full post bodies. A 300KB feed polled every five minutes by ten subscribers is ~26GB/month — **inside** Fly's 100GB free tier but not trivially so, and it scales with subscribers × post length. The mitigation if it bites is excerpt-plus-canonical (see §14), which is also the more POSSE-correct shape: the canonical site should be where the full text lives.
- **External API cost**: **zero.** No Substack API means no per-call cost, no quota, and no vendor bill. The honest mechanism is also the cheap one.
- **Total per post syndicated**: effectively the egress of however many importers fetch it — cents per month at beta scale.

---

## 16. Cross-References

- **US-6.1** — shelf RSS feeds (`docs/user_stories/US-6.1-rss-feeds.md`). This story is the sibling feed and reuses `Feeds.compute_etag/1`, the Atom shape, and the `/api/feeds/u/:handle/…` route family — but **not** its `:optional_auth` posture, and the difference is the point (§4).
- **US-12.1.1** — write a blog post (`docs/user_stories/US-12.1.1-write-blog-post.md`), which owns publishing and visibility. Syndication is downstream of it and never changes visibility.
- **US-12.1.3** — browse the blog, where the "Also at" backlink renders.
- **US-10.2.3** — blog post visibility (`docs/user_stories/US-10.2.3-blog-visibility.md`), the Audience ladder this feed reads from. The syndication feed's minimum is the ladder's maximum.
- **US-8.1** — export data; see the flagged pre-existing gap (blog content is absent from the export).
- **ADR-018** — the unified Audience model (`owner < group < platform < public`).
- **CLAUDE.md — GDPR by Default**: this change touches migrations, Ecto schemas, an event emitter, user-data endpoints, and a dbt model, so `gdpr-review` is mandatory on the diff.
- **notes/phase-1-launch-extension.md — Milestone C**: *"Substack has no official write/publish API. So the honest MVP is … canonical-tagged export … Substack's own RSS-import pointed at The Stacks blog feed … NOT a native OAuth publish — say so."* And: *"being honest about the API constraints* is *the senior signal."*
