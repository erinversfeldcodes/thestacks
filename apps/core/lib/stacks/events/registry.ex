defmodule Stacks.Events.Registry do
  @moduledoc """
      Compile-time dispatch table for event types, plus the hand-maintained
      list of types known to have no subscriber. `@registry` maps event type →
      handler modules (`handlers_for/1`); `@unsubscribed` names real emitted
      types nothing listens to. `all_event_types/0` returns BOTH — replay and
      diagnostics want the whole vocabulary, and a registry-only answer once
      silently hid 32 of 54 emitted types. A test derives the emitted set from
      the codebase and fails when either list goes stale.
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
    # placement.restored — the undo of the above, so it needs exactly the
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
    # The confirmation email is enqueued directly at registration; the event
    # remains for audit/replay but no longer carries the email.
    "user.registered",
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
    # the record that a syndication happened. The feed is generated
    # per request behind an ETag (no cached artefact to invalidate — see the
    # §6 warning in the story about op.feed_cache being the WRONG home for a
    # blog-feed cache), and stg_post_syndications is a view, so a refresh
    # handler would map to no models. The int_syndication_reach insights model
    # is deferred with its x consumer — wiring a refresh for a model
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
    # The four moments of an email change — asked for, proven, undone, or left
    # unanswered until the platform stopped trusting the account. Nothing acts on
    # them: every effect they could trigger (the two emails, the session revoke,
    # the degrade) is done inline by the flow itself, because each one has to
    # happen inside the transaction that makes the change real or not at all.
    # What they are is the audit trail of an account's identity moving.
    "user.email_change_requested",
    "user.email_change_confirmed",
    "user.email_change_reverted",
    "user.email_change_expired",
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
    # The admin decision on a discovered source. Approval already creates the
    # third space inline in the same call and a rejection ends the source's
    # life, so nothing downstream has work to do — these are the audit record of
    # who decided what. Both are emitted with the type passed down as an
    # argument (approve_source/1 and reject_source/1 → transition_source/3 →
    # after_transition/3), so neither string appears at its own emit call.
    "source.approved",
    "source.rejected",
    "costs.refreshed",
    "invite.issued",
    "invite.redeemed",
    "library_import.started",
    "library_import.completed",
    "invite.revoked",
    # The admin queue is the system of record and the owner reads it directly;
    # nothing downstream acts on a submission. A notification handler is the
    # obvious future subscriber, and this line is where it will attach.
    "feedback.submitted"
  ]

  @pending %{
    "offer.opened" =>
      "the marketplace offer flow is deferred (owner ruling 2026-08-19): the " <>
        "offer_threads and offer_messages tables, their schemas and their changesets " <>
        "are built, but no context function opens a thread and no route reaches one, " <>
        "so nothing can emit this yet. OfferNotificationHandler stays registered so " <>
        "the flow lands with its consumer already wired",
    "enrichment.reviews_scraped" =>
      "reviews are planned, not deleted (owner ruling 2026-08-07): " <>
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
