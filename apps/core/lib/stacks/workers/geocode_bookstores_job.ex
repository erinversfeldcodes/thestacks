defmodule Stacks.Workers.GeocodeBookstoresJob do
  @moduledoc """
      Fills in coordinates for bookshops that have none. rule
      needs coordinates on BOTH sides; `op.bookstores` gained lat/lng columns
      that nothing populated, so the nearest-bookshop scan always returned
      `[]` — every unit test passed (each seeded its own coordinates); the
      zero-row sweep found it.

      ⚠️ The throttle is load-bearing: `Nominatim`'s policy (~1 req/s) was
      previously honoured by the ABSENCE of a batch entry point. This module
      is that entry point, so it sleeps `@throttle_ms` between geocodes and
      processes a bounded batch per run — remove either and the policy
      guarantee is gone. Failures leave coordinates nil for the next run.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Enrichment.Bookstore
  alias Stacks.Geocoding

  @throttle_ms 1_100

  @batch_size 25

  @impl true
  def perform(%Oban.Job{}) do
    stores = ungeocoded_stores()

    if stores == [] do
      Logger.debug("GeocodeBookstoresJob: every physical bookshop already has coordinates")
      :ok
    else
      Logger.info("GeocodeBookstoresJob: geocoding #{length(stores)} bookshop(s)")
      geocoded = Enum.reduce(stores, 0, &geocode_one/2)

      Logger.info("GeocodeBookstoresJob: positioned #{geocoded} of #{length(stores)} bookshop(s)")

      :ok
    end
  end

  @doc "Bookshops that have a physical location and no coordinates yet."
  @spec ungeocoded_stores() :: [Bookstore.t()]
  def ungeocoded_stores do
    Repo.all(
      from b in Bookstore,
        where: is_nil(b.latitude) or is_nil(b.longitude),
        where: b.has_physical == true,
        order_by: [asc: b.name],
        limit: @batch_size
    )
  end

  @doc "The delay between requests, in milliseconds. Overridable for tests only."
  @spec throttle_ms() :: non_neg_integer()
  def throttle_ms, do: Application.get_env(:core, :geocode_throttle_ms, @throttle_ms)

  @doc "The documented default throttle, independent of any override."
  @spec default_throttle_ms() :: pos_integer()
  def default_throttle_ms, do: @throttle_ms

  @doc "One run's maximum."
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch_size

  defp geocode_one(store, count) do
    query = Geocoding.query_for(%{name: store.name, country_code: store.country_code})

    result = Geocoding.geocode(query)

    Process.sleep(throttle_ms())

    case result do
      {:ok, %{latitude: lat, longitude: lng}} ->
        store
        |> Ecto.Changeset.change(%{latitude: lat, longitude: lng})
        |> Repo.update()
        |> case do
          {:ok, _} ->
            count + 1

          {:error, changeset} ->
            Logger.warning(
              "GeocodeBookstoresJob: could not save #{store.name}: #{inspect(changeset.errors)}"
            )

            count
        end

      {:error, reason} ->
        Logger.info("GeocodeBookstoresJob: no coordinates for #{store.name} (#{inspect(reason)})")

        count
    end
  end
end
