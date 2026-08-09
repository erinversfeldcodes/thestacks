defmodule Stacks.Events.Registry do
  @moduledoc """
  Compile-time dispatch table for event types, plus the hand-maintained list of the
  types known to have no subscriber.

  Two lists, deliberately kept apart:

    * `@registry` — the dispatch table. Event type to the modules implementing
      `Stacks.Events.Handler` that should run when it is emitted.
    * `@unsubscribed` — event types the system emits that nothing listens to. They
      are real events with real rows in `event_log`; they simply have no subscriber
      today.

  `all_event_types/0` returns both, because replay and diagnostics want more of the
  vocabulary than the subscribed part of it. `handlers_for/1` reads only `@registry`.

  Splitting them is a correction. This moduledoc used to claim `@registry` was "the
  complete catalog … surfaced by `all_event_types/0` for replay/diagnostics" while
  listing 22 of the 54 types actually emitted, so `all_event_types/0` silently
  omitted three fifths of the vocabulary. The alternative — registering every event
  with `[]` — makes the dispatch table lie in the other direction, reading as though
  32 subscriptions exist. Kept apart, `@unsubscribed` is also useful in its own
  right: it is the standing inventory of what this system announces and nobody acts
  on, which is where the next handler is likely needed.

  ## What these two lists are NOT

  They are not an exhaustive catalog of everything the system can emit, and nothing
  makes them one. `Stacks.Events.emit/1` accepts any `event_type` string; it does not
  consult this module. So the honest reading of `all_event_types/0` is *"the event
  types these two lists currently name"* — a maintained inventory, not a guarantee.

  `registry_completeness_test.exs` closes most of the gap by grepping `apps/core/lib`
  for `event_type: "..."` and failing on any literal it cannot find here. That guard
  only sees emit sites where the type is written **at** the emit. An emitter that
  receives its type as an argument is invisible to it — `Stacks.Discovery`'s
  `transition_source/3` is the standing example, and `"source.approved"` /
  `"source.rejected"` are accordingly in neither list despite having payload
  contracts in `Stacks.Events.PayloadContract`. Treat a lookup miss here as "not
  catalogued", never as "not emitted".

  ## Adding a new subscription

  Add an entry to `@registry`:

      "book.created" => [MyApp.SomeHandler]

  The handler module must implement `Stacks.Events.Handler`. If you are adding a new
  event type with no handler, add it to `@unsubscribed` instead — for a literal emit
  site the completeness test fails until it is in one list or the other; for an
  indirect one nothing will remind you, so add it by hand.
  """

  @registry %{
    "book.created" => [
      Stacks.Enrichment.Handlers.BookCreatedHandler,
      Stacks.Enrichment.Handlers.AuthorDiscoveryHandler,
      Stacks.Books.Handlers.CacheInvalidationHandler
    ],
    "book.cover_confirmed" => [
      Stacks.Books.Handlers.CacheInvalidationHandler
    ],
    # The age-gate write (#357). Emitted by `Books.set_visibility_tier/3`, which
    # ALSO evicts BookDetailCache synchronously — see there for why a
    # content-safety control does not wait on this queue. So this subscription is
    # the event's secondary route and its audit trail is the primary point.
    "book.visibility_tier_changed" => [
      Stacks.Books.Handlers.CacheInvalidationHandler
    ],
    # `Stacks.Workers.EnrichBookJob` replaces the placeholder title/author/cover a
    # barcode fast-path book was stored with. Nothing announced it, so the
    # placeholder ("ISBN 9780451524935") stayed on screen for the full
    # BookDetailCache TTL after the real metadata had landed (#357). Here the
    # event IS the only eviction route.
    "book.enriched" => [
      Stacks.Books.Handlers.CacheInvalidationHandler
    ],
    # An edition merge is a WRITE to what `GET /api/books/:id` serves: the work
    # gains a row in its `editions` preload, which is the very thing
    # BookDetailCache holds. Nothing else announced it, so the cache went on
    # serving the pre-merge work for its full 5-minute TTL and the merge
    # prompt's own "View Book" link showed the reader a book without the
    # edition they had just added (#355). Emitted by `Books.merge_edition/2`,
    # so `Stacks.Workers.DiscoverEditionsJob` is covered by the same wire.
    "books.edition_merged" => [
      Stacks.Books.Handlers.CacheInvalidationHandler
    ],
    "blog.post_published" => [
      Stacks.Blog.Handlers.BlogAssociationHandler,
      Stacks.Workers.DbtRefreshHandler
    ],
    "blog.post_updated" => [
      Stacks.Workers.DbtRefreshHandler
    ],
    "blog.post_deleted" => [
      Stacks.Workers.DbtRefreshHandler
    ],
    "blog.associations_suggested" => [
      Stacks.Books.Handlers.CacheInvalidationHandler
    ],
    "user.location_updated" => [
      Stacks.Discovery.Handlers.LocationUpdatedHandler
    ],
    "user.registered" => [
      Stacks.Notifications.EmailConfirmationHandler
    ],
    "placement.created" => [
      Stacks.Feeds.Handlers.PlacementHandler,
      Stacks.Workers.DbtRefreshHandler
    ],
    "placement.moved" => [
      Stacks.Feeds.Handlers.PlacementHandler,
      Stacks.Workers.DbtRefreshHandler
    ],
    # placement.removed (Issue #116 punch #14b): feeds AND a warehouse refresh.
    # A removal decrements mart_community_read_count (an incremental table
    # filtering removed_at is null); created/moved already refresh it via
    # DbtRefreshHandler, so removed — which changes the same numbers — is wired
    # the same way. See Stacks.Workers.DbtRefreshHandler @model_mapping.
    "placement.removed" => [
      Stacks.Feeds.Handlers.PlacementHandler,
      Stacks.Workers.DbtRefreshHandler
    ],
    # placement.restored (#375) — the undo of the above, so it needs exactly the
    # wiring the above needs. The feed regains an entry and
    # mart_community_read_count regains a read; leaving this unsubscribed would
    # make "remove then undo" a state the warehouse and the RSS feed never
    # recover from until the next scheduled dbt run.
    "placement.restored" => [
      Stacks.Feeds.Handlers.PlacementHandler,
      Stacks.Workers.DbtRefreshHandler
    ],
    "enrichment.prices_scraped" => [
      Stacks.Workers.DbtRefreshHandler
    ],
    # Pending, not dead: see @pending below. The subscription is correct for the
    # event it describes and is deliberately kept while the review vertical
    # (US-2.1.1) is built; the completeness test's inverse guard holds it to
    # that designation.
    "enrichment.reviews_scraped" => [
      Stacks.Workers.DbtRefreshHandler
    ],
    "enrichment.author_updated" => [
      Stacks.Workers.DbtRefreshHandler
    ],
    "enrichment.events_discovered" => [
      Stacks.Workers.DbtRefreshHandler
    ],
    "source_health.recorded" => [
      Stacks.Workers.DbtRefreshHandler
    ],
    "group.invitation_sent" => [
      Stacks.Notifications.GroupInvitationHandler
    ],
    "offer.opened" => [
      Stacks.Notifications.OfferNotificationHandler
    ],
    "listing.activated" => [
      Stacks.Notifications.WishlistAvailabilityHandler
    ]
  }

  # Event types that are emitted and have no subscriber.
  #
  # Grouped by why. "No handler" is a conclusion here, not an oversight: for most of
  # these the durable `event_log` row IS the point — an audit trail with no side
  # effect to trigger. Where that is not the reason, the reason is stated.
  #
  # A recurring one, so stated once: every dbt staging model in this codebase is
  # `materialized='view'`, so it always reflects live rows. Wiring DbtRefreshHandler
  # to an event whose only warehouse consumer is a view enqueues a job that refreshes
  # nothing. Only the incremental marts (mart_community_read_count) justify a refresh
  # subscription, which is why placement.created/moved/removed have one and these
  # do not.
  @unsubscribed [
    # ---- Upload / image lifecycle -------------------------------------------
    # The pipeline's own events, and the cluster most obviously "unobserved". They
    # stay unsubscribed because the upload pipeline is already observed on two other
    # channels, and neither is the event bus: `:telemetry` carries the live signal
    # ([:stacks, :upload, :terminal] in IdentifyBookJob, [:stacks, :moderation,
    # :tiering] in Books), and SSE PubSub carries progress to the browser. These
    # events are the durable record of the same transitions — which is exactly what
    # replay and diagnostics want, and exactly what a telemetry counter cannot give
    # you after the fact. `stg_uploaded_images` is a view, so there is no refresh to
    # trigger either. Adding a handler would duplicate telemetry, not extend it.
    "image.submitted",
    "image.rejected",
    "image.resolved",
    # Emitted by GDPR.ImageRetention's 30-day sweep. Deliberately audit-only: the
    # evidence that retention ran is the deliverable.
    "image.expired",

    # ---- Marketplace listing lifecycle --------------------------------------
    # The sibling asymmetry is intentional. "listing.activated" has a handler
    # (WishlistAvailabilityHandler) because activation is the transition a user
    # asked to hear about: a book on their wishlist became available. Sold, removed
    # and expired are the inverse transition, and there is no notification anyone
    # opted into that says a book they wanted is gone — WishlistAvailabilityHandler's
    # 24h dedupe window is built around re-activation, not de-activation. The state
    # change itself is already applied transactionally alongside the emit
    # (update_placement_listing_status/4 clears the placement's listing_status in the
    # same Multi), so nothing downstream is waiting on the event to converge.
    # "listing.created" announces a listing that is not yet purchasable — activation
    # is the event with news in it. Both warehouse consumers, stg_listings and
    # mart_marketplace_activity, are views.
    "listing.created",
    "listing.sold",
    "listing.removed",
    "listing.expired",

    # ---- Placement reading lifecycle ----------------------------------------
    # US-1.6.3 / US-1.6.6. Previously registered as `"x" => []`, which is the same
    # thing said less clearly. stg_bookshelf_placements is a view (reading_status and
    # current_page are always live) and no mart consumes reading progress, so a
    # refresh handler would map to no models. Surfacing re-reads in the activity feed
    # would be a deliberate product change, not a missing wire.
    "placement.reread",
    "placement.reading_started",
    "placement.reading_completed",

    # ---- Books ---------------------------------------------------------------
    # Confirmation already writes its result through Books before emitting; the
    # event records that it happened. It needs no cache invalidation for the
    # reason its sibling `books.edition_merged` (now subscribed, see @registry)
    # did: `confirm/2` emits this only on the branch that CREATES the work, and
    # a work id nobody has read yet cannot have a cache entry to stale.
    "books.confirmed",

    # ---- Blog authoring and associations -------------------------------------
    # Only blog.post_published/updated/deleted change what the warehouse and caches
    # show, and those three are subscribed above. Creating a draft, confirming or
    # dismissing a suggested book association, and commenting are author-side
    # actions whose effect is already persisted.
    "blog.post_created",
    "blog.association_confirmed",
    "blog.association_dismissed",
    "post.comment_created",

    # ---- Social and groups ---------------------------------------------------
    # Only group.invitation_sent needs a side effect (an email), and it has one.
    # Membership changes and blocks are authorisation state, read live from op
    # tables on every request — a handler would have nothing to do.
    "group.created",
    "group.member_joined",
    "group.member_left",
    "group.member_removed",
    "social.user_blocked",
    "social.user_unblocked",

    # ---- Account and profile -------------------------------------------------
    # Audit-only by design, and the GDPR-sensitive end of the catalog: these record
    # that a user changed something about themselves. user.registered (confirmation
    # email) and user.location_updated (discovery re-index) are the two with real
    # side effects, and both are subscribed above.
    "user.profile_updated",
    "user.profile_visibility_changed",
    "user.password_changed",
    "user.notifications_updated",
    "user.visibility_recap_completed",

    # ---- Partner ingest ------------------------------------------------------
    # Partner pushes are one-directional and land synchronously; the event is the
    # receipt.
    "partner.inventory_synced",
    "partner.event_created",
    "partner.event_deleted",

    # ---- Discovery and platform operations -----------------------------------
    # Job-completion records. enrichment.events_discovered has a refresh handler
    # because int_event_matches consumes it; these have no equivalent consumer.
    "enrichment.sources_discovered",
    "enrichment.author_sources_discovered",
    "third_space.created",
    "third_space.delisted",
    "costs.refreshed"
  ]

  # Catalogued event types whose emitter does not exist YET — the consumer-side
  # wiring (handlers, payload contract, dbt mapping) is deliberately kept for a
  # planned vertical. Every entry carries the story/ruling that keeps it, so
  # "pending" is a claim someone made on the record, not a place orphans hide:
  # the completeness test's inverse guard fails any catalogued type that is
  # neither emitted nor named here, and fails a pending entry the moment an
  # emitter appears (it must then leave this map).
  @pending %{
    "enrichment.reviews_scraped" =>
      "US-2.1.1 — reviews are planned, not deleted (owner ruling 2026-08-07, #336): " <>
        "the Wave 2 cleanup removed the scraper-side emitter but the review vertical " <>
        "returns; its handler, payload contract and dbt models stay wired"
  }

  # An event type in both lists would make all_event_types/0 return duplicates and
  # leave it ambiguous which list is authoritative. Fail the compile instead.
  @overlap Enum.filter(@unsubscribed, &Map.has_key?(@registry, &1))
  if @overlap != [] do
    raise CompileError, description: "event type in @registry and @unsubscribed: #{@overlap}"
  end

  # A pending type must be catalogued — the designation qualifies an entry in one
  # of the two lists above; a pending entry for an uncatalogued type is a typo.
  @uncatalogued_pending Enum.reject(
                          Map.keys(@pending),
                          &(Map.has_key?(@registry, &1) or &1 in @unsubscribed)
                        )
  if @uncatalogued_pending != [] do
    raise CompileError,
      description: "pending event type not in @registry/@unsubscribed: #{@uncatalogued_pending}"
  end

  @doc """
  Returns the list of handler modules registered for the given event type.

  Returns an empty list if no handlers are registered.
  """
  @spec handlers_for(String.t()) :: [module()]
  def handlers_for(event_type) when is_binary(event_type) do
    overrides = Application.get_env(:core, :test_handler_overrides, %{})

    case Map.get(overrides, event_type) do
      nil -> Map.get(@registry, event_type, [])
      handlers -> handlers
    end
  end

  @doc """
  Returns every event type this module catalogues, sorted — subscribed or not.

  The vocabulary for replay tooling and diagnostics, so it deliberately includes
  types with no handler. It is the union of two hand-maintained lists, not a derived
  fact about the codebase: absence here means "not catalogued", not "never emitted"
  (see the moduledoc). Use `handlers_for/1` to ask what will actually run.
  """
  @spec all_event_types() :: [String.t()]
  def all_event_types do
    Enum.sort(Map.keys(@registry) ++ @unsubscribed)
  end

  @doc """
  Returns the event types that are emitted but have no subscriber.

  The standing inventory of what this system announces and nothing acts on.
  """
  @spec unsubscribed_event_types() :: [String.t()]
  def unsubscribed_event_types, do: @unsubscribed

  @doc """
  Catalogued event types with no emitter yet, mapped to the reason each one's
  consumer-side wiring is kept. See `@pending`.
  """
  @spec pending_event_types() :: %{String.t() => String.t()}
  def pending_event_types, do: @pending
end
