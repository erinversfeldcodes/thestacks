defmodule Stacks.Workers.GeographicDiscoveryJob do
  @moduledoc """
  Oban worker that triggers source discovery for a geographic location.

  Accepts `%{"city" => city, "country_code" => country_code}`. Builds
  multiple search queries targeting bookshops and community spaces in
  the area, then enqueues a `SourceDiscoveryJob` for each query.

  Triggered by the `user.location_updated` event via
  `Stacks.Discovery.Handlers.LocationUpdatedHandler`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Workers.SourceDiscoveryJob

  @impl true
  def perform(%Oban.Job{args: %{"city" => city, "country_code" => country_code}}) do
    queries = build_queries(city, country_code)
    location = %{"city" => city, "country_code" => country_code}

    Logger.info(
      "GeographicDiscoveryJob: enqueuing #{length(queries)} discovery queries for #{city}, #{country_code}"
    )

    Enum.each(queries, fn query ->
      case %{query: query, location: location}
           |> SourceDiscoveryJob.new()
           |> Oban.insert() do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "GeographicDiscoveryJob: failed to enqueue query #{inspect(query)}: #{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  defp build_queries(city, country_code) do
    country = country_name(country_code)

    [
      "bookshops in #{city}",
      "independent bookstores #{city}",
      "reading groups #{city}",
      "book clubs #{city} #{country}",
      "literary events #{city}"
    ]
  end

  # Map common country codes to names for richer search queries.
  defp country_name("ZA"), do: "South Africa"
  defp country_name("GB"), do: "United Kingdom"
  defp country_name("US"), do: "United States"
  defp country_name("AU"), do: "Australia"
  defp country_name("CA"), do: "Canada"
  defp country_name("NZ"), do: "New Zealand"
  defp country_name("IE"), do: "Ireland"
  defp country_name(code), do: code
end
