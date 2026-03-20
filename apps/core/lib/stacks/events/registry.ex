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
      Stacks.Enrichment.Handlers.AuthorDiscoveryHandler
    ],
    "user.location_updated" => [
      Stacks.Discovery.Handlers.LocationUpdatedHandler
    ]
  }

  @doc """
  Returns the list of handler modules registered for the given event type.

  Returns an empty list if no handlers are registered.
  """
  @spec handlers_for(String.t()) :: [module()]
  def handlers_for(event_type) when is_binary(event_type) do
    Map.get(@registry, event_type, [])
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
