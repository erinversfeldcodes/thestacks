defmodule Stacks.Discovery.Handlers.LocationUpdatedHandler do
  @moduledoc """
    On `user.location_updated`, enqueues a `GeographicDiscoveryJob` for the
    user's area. The payload is UUID-only (city/country never enter
    `op.event_log`), so the handler reads the CURRENT city/country off the
    user record — meaning rapid location changes discover against the latest
    location only, the deliberate cost of keeping PII out of the event log.
    A since-deleted user is a no-op success.
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
