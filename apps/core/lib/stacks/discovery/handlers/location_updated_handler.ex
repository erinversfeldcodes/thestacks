defmodule Stacks.Discovery.Handlers.LocationUpdatedHandler do
  @moduledoc """
  Event handler that triggers geographic source discovery when a user
  updates their location.

  On `user.location_updated`: extracts city and country_code from the
  event payload and enqueues a `GeographicDiscoveryJob` to search for
  bookshops and community spaces in that area.
  """

  @behaviour Stacks.Events.Handler

  require Logger

  alias Stacks.Workers.GeographicDiscoveryJob

  @impl true
  def handle_event(%{
        event_type: "user.location_updated",
        payload: %{city: city, country_code: country_code}
      })
      when is_binary(city) and is_binary(country_code) do
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

  # Handle string-keyed payloads (e.g., from JSON deserialization)
  def handle_event(%{
        event_type: "user.location_updated",
        payload: %{"city" => city, "country_code" => country_code}
      })
      when is_binary(city) and is_binary(country_code) do
    handle_event(%{
      event_type: "user.location_updated",
      payload: %{city: city, country_code: country_code}
    })
  end

  # Catch-all: ignore events we don't care about
  def handle_event(_event), do: :ok
end
