defmodule Stacks.Workers.BuildScraperIndexJob do
  @moduledoc """
      Rebuilds each store's ISBN→product-path index in the scraper service.
      Four of six Shopify targets carry the ISBN in `sku`/prose but not the
      product handle, so they can't be addressed by ISBN without an index. The
      index lives in the scraper's process and dies with it ON PURPOSE
      (nothing durable holds a shop's catalogue), so it must be rebuilt after
      every deploy — else those stores answer `IndexRequired` forever. Separate
      from scraping because a sweep is ~20 requests against a 10/min-limited
      shop: minutes of rate-limiter waiting that must not sit inside a price
      scrape. Runs from cron and on `IndexRequired`.
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
