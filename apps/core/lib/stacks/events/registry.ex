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
    "book.visibility_tier_changed" => [
      Stacks.Books.Handlers.CacheInvalidationHandler
    ],
    "book.enriched" => [
      Stacks.Books.Handlers.CacheInvalidationHandler
    ],
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

  @unsubscribed [
    "image.submitted",
    "image.rejected",
    "image.resolved",
    "image.expired",
    "listing.created",
    "listing.sold",
    "listing.removed",
    "listing.expired",
    "placement.reread",
    "placement.reading_started",
    "placement.reading_completed",
    "books.confirmed",
    "blog.post_created",
    "blog.association_confirmed",
    "blog.association_dismissed",
    "post.comment_created",
    # US-6.2.1: the record that a syndication happened. The feed is generated
    # per request behind an ETag (no cached artefact to invalidate — see the
    # §6 warning in the story about op.feed_cache being the WRONG home for a
    # blog-feed cache), and stg_post_syndications is a view, so a refresh
    # handler would map to no models. The int_syndication_reach insights model
    # is deferred with its US-12.x consumer — wiring a refresh for a model
    # that doesn't exist yet is the "built but not wired" shape inverted.
    "post.syndicated",
    "group.created",
    "group.member_joined",
    "group.member_left",
    "group.member_removed",
    "social.user_blocked",
    "social.user_unblocked",
    "user.profile_updated",
    "user.profile_visibility_changed",
    "user.password_changed",
    "user.notifications_updated",
    "user.visibility_recap_completed",
    "partner.inventory_synced",
    "partner.event_created",
    "partner.event_deleted",
    "enrichment.sources_discovered",
    "enrichment.author_sources_discovered",
    "third_space.created",
    "third_space.delisted",
    "costs.refreshed",
    "invite.issued",
    "invite.redeemed",
    "library_import.started",
    "library_import.completed",
    "invite.revoked"
  ]

  @pending %{
    "enrichment.reviews_scraped" =>
      "US-2.1.1 — reviews are planned, not deleted (owner ruling 2026-08-07, #336): " <>
        "the Wave 2 cleanup removed the scraper-side emitter but the review vertical " <>
        "returns; its handler, payload contract and dbt models stay wired"
  }

  @overlap Enum.filter(@unsubscribed, &Map.has_key?(@registry, &1))
  if @overlap != [] do
    raise CompileError, description: "event type in @registry and @unsubscribed: #{@overlap}"
  end

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
