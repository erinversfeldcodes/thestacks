defmodule Stacks.Discovery.Handlers.LocationUpdatedHandler do
  @moduledoc """
  Event handler that triggers geographic source discovery when a user
  updates their location.

  On `user.location_updated`: the event payload is UUID-only (it carries no
  PII — city/country_code are never written into `op.event_log`; see
  `Stacks.Accounts.update_location/2` and `Stacks.Events`). The handler
  resolves the user from the event's `aggregate_id`, reads the *current* `city`
  and `country_code` off the user record, and enqueues a
  `GeographicDiscoveryJob` for that area.

  ## Semantic note

  Because location is read from the live user record rather than an as-of-event
  snapshot in the payload, a rapid sequence of location updates discovers
  against the user's *latest* location, not each intermediate one. This is an
  acceptable trade-off for discovery — we only ever want to search the user's
  real, current area — and is the deliberate cost of keeping PII out of the
  event log.

  If the user no longer exists (e.g. GDPR erasure occurred between emit and
  dispatch) or has no city/country set, the handler logs and returns `:ok`
  without enqueuing — it never crashes the dispatch pipeline.
  """

  @behaviour Stacks.Events.Handler

  require Logger

  alias Stacks.Accounts
  alias Stacks.Accounts.User
  alias Stacks.Workers.GeographicDiscoveryJob

  @impl true
  def handle_event(%{event_type: "user.location_updated", aggregate_id: user_id})
      when is_binary(user_id) do
    case Accounts.get_user(user_id) do
      %User{city: city, country_code: country_code}
      when is_binary(city) and is_binary(country_code) ->
        enqueue_discovery(city, country_code)

      %User{} ->
        Logger.info(
          "LocationUpdatedHandler: user #{user_id} has no city/country set; skipping discovery"
        )

        :ok

      nil ->
        Logger.info(
          "LocationUpdatedHandler: user #{user_id} not found (likely erased); skipping discovery"
        )

        :ok
    end
  end

  # Catch-all: ignore events we don't care about (and malformed
  # location-updated events without a usable aggregate_id).
  def handle_event(_event), do: :ok

  defp enqueue_discovery(city, country_code) do
    Logger.info(
      "LocationUpdatedHandler: enqueuing geographic discovery for #{city}, #{country_code}"
    )

    case %{city: city, country_code: country_code}
         |> GeographicDiscoveryJob.new()
         |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "LocationUpdatedHandler: failed to enqueue geographic discovery for #{city}, #{country_code}: #{inspect(reason)}"
        )

        :ok
    end
  end
end
