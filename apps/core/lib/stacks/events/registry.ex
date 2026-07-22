defmodule Stacks.Events.Registry do
  @moduledoc """
  Central compile-time registry mapping event types to handler modules.

  Each entry maps an event type string to a list of modules that implement
  `Stacks.Events.Handler`. The registry is a plain module attribute — no
  GenServer or runtime state is needed.

  ## Adding a new subscription

  Add an entry to the `@registry` map below:

      "book.created" => [MyApp.SomeHandler]

  The handler module must implement `Stacks.Events.Handler`.
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
      Stacks.Feeds.Handlers.PlacementHandler
    ],
    # Reading-lifecycle events (US-1.6.6), emitted by
    # Shelving.update_reading_progress/3. Registered with an EMPTY handler set
    # deliberately: `stg_bookshelf_placements` is a dbt `view` (it always
    # reflects the live reading_status/current_page — nothing to refresh), and
    # no mart consumes reading progress today, so a DbtRefreshHandler would map
    # to no models and enqueue a no-op job. Registering with `[]` keeps the
    # registry the complete catalog of emitted event types (surfaced by
    # `all_event_types/0` for replay/diagnostics) without inventing a phantom
    # handler. Add a handler here if/when a reading-analytics mart lands.
    "placement.reading_started" => [],
    "placement.reading_completed" => [],
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
  Returns all registered event type strings.

  Useful for documentation, replay tooling, and diagnostics.
  """
  @spec all_event_types() :: [String.t()]
  def all_event_types do
    Map.keys(@registry)
  end
end
