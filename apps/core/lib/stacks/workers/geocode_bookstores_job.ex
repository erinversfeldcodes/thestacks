defmodule Stacks.Workers.GeocodeBookstoresJob do
  @moduledoc """
  Fills in coordinates for bookshops that have none.

  ## Why this exists

  The 500 m pairing rule at the heart of US-3.1.1 needs coordinates on **both** sides — a
  third space and a bookshop. `op.bookstores` gained `latitude`/`longitude` on 2026-07-28
  and **nothing populated them**, so `Discovery.create_third_space/1`'s nearest-bookshop
  scan always returned `[]`, `nearest_bookshop_km` was always `nil`, and the filter that is
  the page's entire premise could never return a row. Every unit test passed, because each
  set the coordinates it needed; the zero-row sweep is what found it.

  ## The throttle is the point, and it is load-bearing

  ⚠️ `Stacks.Geocoding.Nominatim`'s documentation previously said the **absence** of a batch
  entry point was what structurally honoured Nominatim's ~1 req/sec usage policy. This module
  is that entry point, so the guarantee has to be replaced rather than dropped:

    * requests are **strictly serial** — no `Task.async_stream`, no concurrency;
    * `@throttle_ms` sits between them and defaults to **1100 ms**, above the ~1 req/sec
      policy rather than exactly at it;
    * `@batch_size` caps one run, so a large table cannot become a long unattended crawl.

  The delay is overridable (`:core, :geocode_throttle_ms`) **for tests only** — a suite that
  actually slept would be unusable, and a throttle nobody can test is a throttle nobody
  knows works. The default is asserted in the tests so lowering it is a visible change.

  ## What it deliberately does not do

    * **Online-only shops are skipped.** `has_physical: false` means there is no place to
      geocode; `Loot` is a website, and giving it a coordinate would put a phantom shop on
      the map and let the 500 m rule pair a space with a warehouse.
    * **Existing coordinates are never overwritten.** An owner correcting a bad geocode must
      not have their fix reverted on the next run.

  ⚠️ **Known limitation, recorded rather than hidden: chains resolve to one branch.**
  Geocoding "Exclusive Books, ZA" returns *an* Exclusive Books, not all of them, so a chain
  gets one arbitrary location. For the independents that make up most of the list this is
  accurate; for chains it is a single representative point, and the 500 m rule will therefore
  pair spaces against that one branch. Fixing it properly needs per-branch rows, which is a
  data-model change, not a geocoding change.
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
