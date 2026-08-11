defmodule Stacks.Workers.BuildScraperIndexJob do
  @moduledoc """
  Rebuilds each store's ISBN→product-path index in the scraper service.

  ## Why this job exists

  Four of the six Shopify targets carry the ISBN in `sku` or in prose but not in the
  product handle, so their products cannot be addressed by ISBN directly. An
  ISBN→path index makes them work — Wordsworth prices R215.00 for "Where's Spot?" at
  `/products/wheres-spot-2`, a handle nothing like its ISBN.

  That index lives in the scraper service's process and **dies with it**, which is
  deliberate: nothing durable holds a copy of anyone's catalogue. The cost of that
  choice is that it has to be rebuilt, and this is what rebuilds it. Without this
  job, every store needing an index answers `IndexRequired` forever after a deploy.

  ## Why it is separate from scraping

  A sweep is up to twenty requests against a shop limited to ten a minute, so it
  waits on the rate limiter and takes minutes. A price lookup must never do that —
  measured: an inline build exhausted Wordsworth's budget on its first page and
  returned `rate limit exceeded`.

  Stores are rebuilt one at a time rather than concurrently. The limiter is
  per-domain so parallelism would not speed any single store up, and a burst of
  simultaneous sweeps across eleven shops is exactly the kind of load this design
  exists to avoid.
  """

  use Oban.Worker, queue: :scraper, max_attempts: 2

  require Logger

  alias Stacks.Enrichment.Prices

  @impl true
  def perform(%Oban.Job{args: %{"store" => store_name}}) do
    client = Application.get_env(:core, :scraper_client, Stacks.Enrichment.ScraperClient)

    case client.build_index(store_name) do
      {:ok, entries} ->
        Logger.info("BuildScraperIndexJob: #{store_name} indexed #{entries} ISBNs")
        :ok

      {:error, reason} ->
        Logger.warning("BuildScraperIndexJob: #{store_name} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: %{}}) do
    stores = Prices.stores_needing_index()

    if stores == [] do
      Logger.info("BuildScraperIndexJob: no stores need an ISBN index")
      :ok
    else
      Enum.each(stores, fn store ->
        %{store: store.scraper_module}
        |> __MODULE__.new(unique: [period: 3600, fields: [:worker, :args]])
        |> Oban.insert()
      end)

      Logger.info("BuildScraperIndexJob: enqueued #{length(stores)} index build(s)")
      :ok
    end
  end
end
